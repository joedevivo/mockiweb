-module(mockiweb_tests).

-include_lib("eunit/include/eunit.hrl").

mockiweb_basic_test() ->
    ibrowse:start(),
    {ok, _Pid, ProcessName} = mockiweb:new(),
    Port = mockiweb:port(ProcessName),

    {ok, "404", _ResponseHeaders, "" } = ibrowse:send_req("http://localhost:" ++ integer_to_list(Port) ++ "/organization/joes/rule", [
        {"Content-Type", "application/json"}
        ], get),

    History = mockiweb:history(ProcessName),
    ?assertEqual(1, length(History)),
    ok.

mockiweb_expect_test() ->
    ibrowse:start(),
    {ok, _Pid, ProcessName} = mockiweb:new(),
    Port = mockiweb:port(ProcessName),
    io:format("~p~n", [Port]),
    mockiweb:expect(ProcessName, ["thing", id], [], "", [{"Status-Code", 200}], "hi!"),

    {ok, "200", _ResponseHeaders, "hi!" } = ibrowse:send_req("http://localhost:" ++ integer_to_list(Port) ++ "/thing/2", [
        {"Content-Type", "application/json"}
        ], get),

    [{Path, {["thing", id], [], "", [{"Status-Code", 200}], "hi!"}, {200, [{"Status-Code", 200}], "hi!"}}] = mockiweb:history(ProcessName),
    ?assertEqual("/thing/2", Path),
    ok.
