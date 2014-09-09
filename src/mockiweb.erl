-module(mockiweb).

-behaviour(gen_server).

%% API
-export([
         new/0,
         new/1,
         start_link/1,
         stop/1,
         expect/6,
         respond/2,
         port/1,
         history/1
        ]).

%% gen_server callbacks
-export([
         init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3
        ]).

-define(SERVER, ?MODULE).

-record(state, {
          port :: inet:port_number(),
          expectations = [] :: list(),
          routes :: list(),
          requests = [] :: list()
}).

%% Types
-type route() :: [string() | atom()].
-type header() :: {string(), string()}.
-type headers() :: [header()].
-type body() :: string().

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

%%%===================================================================
%%% API
%%%===================================================================

%% @doc This spins up a webserver on a random port
-spec new() -> ignore | {error, _} | {'ok', pid(), atom()}.
new() ->
    new(random_port()).

%% @doc spins up a webserver on a specific port
-spec new(inet:port_number()) -> ignore | {error, _} | {'ok', pid(), atom()}.
new(Port) ->
    case check_port(Port) of
        in_use -> {error, in_use};
        ok ->
            ?MODULE:start_link(Port)
    end.

%% @doc Starts the server
-spec start_link(inet:port_number()) -> {ok, pid(), atom()} | ignore | {error, any()}.
start_link(Port) ->
    ProcessName = server_name(Port),
    case gen_server:start_link({local, ProcessName}, ?MODULE, [Port, ProcessName], []) of
        {ok, Pid} ->
            {ok, Pid, ProcessName};
        Other ->
            Other
    end.

-spec stop(atom()) -> ok.
stop(ProcName) ->
    gen_server:cast(ProcName, stop).

%% TODO, I really don't like this 6 tuple. there has to be a better
%% way. one that might even take http req methods into account
-spec expect(atom(), route(), headers(), body(), headers(), body()) -> ok.
expect(ProcessName, Route, Headers, Body, ReturnHeaders, ReturnBody) ->
    gen_server:cast(ProcessName, {expect, Route, Headers, Body, ReturnHeaders, ReturnBody}).

-spec respond(atom(), mochiweb_request:request()) -> {non_neg_integer(), headers(), body()}.
respond(ProcessName, Req) ->
    {ResponseCode, ResponseHeaders, ResponseBody} = gen_server:call(ProcessName, {respond, Req}),
    Req:respond({ResponseCode,
                 ResponseHeaders,
                 ResponseBody}).

-spec port(atom()) -> inet:port_address().
port(ProcessName) ->
    gen_server:call(ProcessName, port).

-spec history(atom()) -> list().
history(ProcessName) ->
    gen_server:call(ProcessName, history).

-spec server_name(inet:port_number()) -> atom().
server_name(Port) ->
    list_to_atom("mockiweb_server_" ++ integer_to_list(Port)).

-spec mochiweb_name(inet:port_number()) -> atom().
mochiweb_name(Port) ->
    list_to_atom("mockiweb_server_" ++ integer_to_list(Port) ++ "_mochiweb_http").

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%% @private
%% @doc initializes the server
-spec init(list()) -> {ok, #state{}} |
                      {ok, #state{}, non_neg_integer()} |
                      {ok, #state{}, hibernate} |
                      ignore |
                      {stop, any()}.
init([Port, ProcessName]) ->
    Loop = fun(Req) ->
        ?MODULE:respond(ProcessName, Req)
    end,
    mochiweb_http:start([
        {name, mochiweb_name(Port)},
        {loop, Loop},
        {ip, {0,0,0,0}},
        {port, Port}
    ]),

    {ok, #state{port = Port}}.

%% @private
%% @doc Handling call messages
%% TODO: deserves a better spec, but also deserves a better API.
-spec handle_call(history | port | {respond, term()}, {pid(), term()}, #state{}) ->
                                   {reply, term(), #state{}} |
                                   {reply, term(), #state{}, non_neg_integer()} |
                                   {noreply, #state{}} |
                                   {noreply, #state{}, non_neg_integer()} |
                                   {stop, term(), term(), #state{}} |
                                   {stop, term(), #state{}}.
handle_call(history, _From, #state{requests=History}=State) ->
    {reply, History, State};
handle_call(port, _From, #state{port=Port}=State) ->
    {reply, Port, State};
handle_call({respond, Req},
            _From,
            #state{
               requests=History,
               expectations=Es
                  } = State) ->
    %% * get the path from Req
    Path = Req:get(path),
    %% * match the path to a route from #state.expectations
    {M, Response} = case great_expectations(Path, Es) of
        [] -> %% No ticket
            {nomatch, {404, [], ""}};
        %% If there's more than one match, no probalo! They're priority sorted.
        [Match|_] ->
            %% * Extract 'Status-Code' from the response headers of the expectation matched
            {_Route, _Headers, _Body, RHeaders, RBody} = Match,
            ResponseCode = proplists:get_value("Status-Code", RHeaders, 200),
            {Match, {ResponseCode, RHeaders, RBody}}
    end,
    %% * deliver a tuple of {Code::integer(), Headers::[header()], Body::string()
    NewHistory = [{Path, M, Response}|History],
    {reply, Response, State#state{requests=NewHistory}};
handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.

%% @private
%% @doc Handling cast messages
%% TODO: again, API and spec improvements
-spec handle_cast(term(), #state{}) -> {noreply, #state{}} |
                                 {noreply, #state{}, non_neg_integer()} |
                                 {stop, term(), #state{}}.
handle_cast({expect,  Route, Headers, Body, ReturnHeaders, ReturnBody}, #state{expectations=Es} = State) ->
    NewState = State#state{expectations = [{Route, Headers, Body, ReturnHeaders, ReturnBody} | Es]},
    {noreply, NewState};
handle_cast(stop, #state{port=P} = State) ->
    mochiweb_http:stop(mochiweb_name(P)),
    {stop, normal, State};
handle_cast(_Msg, State) ->
    {noreply, State}.

%% @private
%% @doc Handling all non call/cast messages
-spec handle_info(term(), #state{}) -> {noreply, #state{}} |
                                       {noreply, #state{}, non_neg_integer()} |
                                       {stop, term(), #state{}}.
handle_info(_Info, State) ->
    {noreply, State}.

%% @private
%% @doc  This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_server terminates
%% with Reason. The return value is ignored.
-spec terminate(normal | shutdown | {shutdown,term()} | term(), #state{}) -> any().
terminate(_Reason, _State) ->
    ok.

%% @private
%% @doc  Convert process state when code is changed
-spec code_change(term(), #state{}, term()) -> {ok, #state{}}.
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

great_expectations(Path, Expectations) ->
    PathTokens = string:tokens(Path, "/"),
    %% Go through list of Expectations.
    Filtered = lists:filter(
                 fun(X) -> path_match(PathTokens, element(1, X)) end,
                 Expectations),
    priority_sort(Filtered).

path_match([], []) -> true;
path_match([], _) -> false;
path_match(_, []) -> false;
path_match([_PathHead|PathTail], [RouteHead|RouteTail]) when is_atom(RouteHead) ->
    path_match(PathTail, RouteTail);
path_match([Head|PathTail], [Head|RouteTail]) ->
    path_match(PathTail, RouteTail);
path_match(_, _) ->
    false.

priority_sort(Expectations) ->
    lists:sort(fun route_sort/2, Expectations).

route_sort(A,B) when is_tuple(A), is_tuple(B) ->
    route_sort(element(1, A), element(1, B));
route_sort([],[]) ->
    false;
route_sort([A|_], [B|_]) when is_atom(A), is_list(B) ->
    false;
route_sort([A|_], [B|_]) when is_list(A), is_atom(B) ->
    true;
%% This clause means that the head of both lists is either
route_sort([_|ARest], [_|BRest]) ->
    route_sort(ARest, BRest).

%% Thanks https://github.com/opscode/chef_db/blob/master/itest/pg_test_util.erl
%% @doc If lucky, return an unused port. This is a cheat that opens a
%% UDP port letting the OS pick the port, captures that port, and then
%% closes the socket returning the port number. While not reliable,
%% this seems to work to obtain an "unused" port for setting up
%% services needed for testing.
random_port() ->
    {ok, S} = gen_udp:open(0, [binary, {active, once}]),
    {ok, Port} = inet:port(S),
    gen_udp:close(S),
    Port.

-spec check_port(inet:port_number()) -> ok | in_use.
check_port(Port) ->
    case gen_tcp:connect("127.0.0.1", Port, []) of
        {ok, S} ->
            gen_tcp:close(S),
            in_use;
        {error,econnrefused} ->
            ok
    end.

-ifdef(TEST).
path_match_test() ->
    ?assert(path_match([],[])),
    ?assert(path_match(["first", "second", "third"], ["first", atom, "third"])),
    ?assertNot(path_match(["1", "2", "3", "4"], ["1", "2", "3"])),
    ?assert(path_match(["1", "2", "3", "4"], ["1", "2", "3", "4"])),
    ok.

priority_sort_test() ->
    Es = [ {[one, two, three, four], fourth},
           {[one, "two", "three", four], third},
           {["one", "two", three, four], second},
           {["one", "two","three", four], first}],
    SortedEs = priority_sort(Es),
    ?assertEqual(first, element(2, lists:nth(1, SortedEs))),
    ?assertEqual(second, element(2, lists:nth(2, SortedEs))),
    ?assertEqual(third, element(2, lists:nth(3, SortedEs))),
    ?assertEqual(fourth, element(2, lists:nth(4, SortedEs))),
    ok.

priority_sort_same_route_test() ->
    Es = [
          {[one, two, three, four], sixth},
          {["one", two, "three", "four"], fourth},
          {["one", "two", "three", four], second},
          {[one, "two", "three", "four"], fifth},
          {["one", "two", three, "four"], third},
          {["one", "two", "three", "four"], first}
         ],
    SortedEs = priority_sort(Es),
    ?assertEqual(first, element(2, lists:nth(1, SortedEs))),
    ?assertEqual(second, element(2, lists:nth(2, SortedEs))),
    ?assertEqual(third, element(2, lists:nth(3, SortedEs))),
    ?assertEqual(fourth, element(2, lists:nth(4, SortedEs))),
    ?assertEqual(fifth, element(2, lists:nth(5, SortedEs))),
    ?assertEqual(sixth, element(2, lists:nth(6, SortedEs))),
    ok.

-endif.
