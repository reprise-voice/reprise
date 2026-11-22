#!/usr/bin/env escript
%% Copyright (C) 2026 Vonix LLC
%% SPDX-License-Identifier: MPL-2.0
%% evaluate an expression on the local kazoo node (ecallmgr or kazoo_apps; connects like sup does)
main([Expr]) ->
    _ = os:cmd("epmd -daemon"),
    _ = net_kernel:stop(),
    Host = net_adm:localhost(),
    Name = list_to_atom("reprisecmd_" ++ integer_to_list(rand:uniform(99999)) ++ "@" ++ Host),
    {ok, _} = net_kernel:start([Name, longnames]),
    true = erlang:set_cookie(node(), list_to_atom(os:getenv("KAZOO_COOKIE", "change_me"))),
    %% KAZOO_NODE is set in the pods (ecallmgr / kazoo_apps)
    Target = list_to_atom(os:getenv("KAZOO_NODE", "ecallmgr") ++ "@" ++ Host),
    pong = net_adm:ping(Target),
    {ok, Tokens, _} = erl_scan:string(Expr ++ "."),
    {ok, Exprs} = erl_parse:parse_exprs(Tokens),
    T0 = erlang:monotonic_time(millisecond),
    R = rpc:call(Target, erl_eval, exprs, [Exprs, erl_eval:new_bindings()], 30000),
    Ms = erlang:monotonic_time(millisecond) - T0,
    case R of
        {value, V, _} -> io:format("~p  (~bms)~n", [V, Ms]);
        Other -> io:format("RPC: ~p~n", [Other])
    end.
