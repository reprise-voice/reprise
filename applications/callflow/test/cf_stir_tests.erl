%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2026, Vonix LLC
%%% @doc `cf_stir' against a stand-in `stir@inbound' compiled here: the
%%% module absent, a call with nothing to verify, a verdict put on the
%%% channel and the record, an error, a crash, and an answer later than the
%%% deadline, none of which may change the call or leave anything in the
%%% caller's mailbox. Every one of them clears the `STIR-*' channel
%%% variables the call arrived with first.
%%% @end
%%%-----------------------------------------------------------------------------
-module(cf_stir_tests).

-include_lib("eunit/include/eunit.hrl").

-define(INBOUND, 'stir@inbound').
-define(FAKE_FILE, "stir@inbound.erl").
-define(ACCOUNT_ID, <<"account0000000000000000000000001">>).
-define(TOKEN, <<"resource000000000000000000000001@", (?ACCOUNT_ID)/binary>>).

%% The stand-in dispatches on the caller number, which the facts carry.
-define(FAKE_SOURCE,
        "-module('stir@inbound').\n"
        "-export([verify/1]).\n"
        "verify(#{<<\"caller_number\">> := <<\"+15550000001\">>}) ->\n"
        "    {ok, #{<<\"STIR-Verstat\">> => <<\"TN-Validation-Passed\">>,\n"
        "           <<\"STIR-Attest\">> => <<\"A\">>,\n"
        "           <<\"STIR-Verdict-Source\">> => <<\"carrier\">>}};\n"
        "verify(#{<<\"caller_number\">> := <<\"+15550000002\">>}) -> {error, <<\"ignore\">>};\n"
        "verify(#{<<\"caller_number\">> := <<\"+15550000003\">>}) -> erlang:error(boom);\n"
        "verify(#{<<\"caller_number\">> := <<\"+15550000004\">>}) -> timer:sleep(3000), {ok, #{<<\"STIR-Verstat\">> => <<\"late\">>}};\n"
        "verify(#{<<\"caller_number\">> := <<\"+15550000005\">>}) -> {error, <<\"disabled\">>};\n"
        "verify(#{<<\"caller_number\">> := <<\"+15550000006\">>}) -> not_a_result;\n"
        "verify(#{<<\"caller_number\">> := <<\"+15550000007\">>}) -> {ok, #{}};\n"
        "verify(Facts) -> {ok, Facts}.\n"
       ).

%%------------------------------------------------------------------------------
%% Without the stir application
%%------------------------------------------------------------------------------

absent_test_() ->
    {'setup'
    ,fun hide_stir/0
    ,fun restore_stir/1
    ,fun(_) ->
             Call = call(<<"+15550000001">>, carrier_headers(), [{<<"identity">>, <<"jws">>}]),
             Verified = cf_stir:maybe_verify(Call),
             [{"no stir module: nothing is decided"
              ,?_assertEqual(<<"unknown">>, kapps_call:custom_channel_var(<<"STIR-Verstat">>, Verified))
              }
             ,{"no stir module: no verdict"
              ,?_assertEqual('undefined', kapps_call:custom_channel_var(<<"STIR-Verdict-Source">>, Verified))
              }
             ,{"no stir module: nothing published, nothing in the mailbox", ?_assertEqual([], flush())}
             ]
     end
    }.

%%------------------------------------------------------------------------------
%% The clearing, which happens whatever else does
%%------------------------------------------------------------------------------

clear_test_() ->
    {'setup'
    ,fun unload_fake/0
    ,fun(_) -> 'ok' end
    ,fun(_) ->
             [{"an honest call gains `unknown' and publishes nothing", fun clear_honest/0}
             ,{"an injected verdict is taken off the record and the channel", fun clear_injected/0}
             ]
     end
    }.

clear_honest() ->
    Call = call(<<"+15550000001">>, [], []),
    Cleared = cf_stir:clear(Call),
    ?assertEqual(<<"unknown">>, kapps_call:custom_channel_var(<<"STIR-Verstat">>, Cleared)),
    ?assertEqual([], flush()).

%% A peer that put `X-ecallmgr_STIR-Attest' in its INVITE has a real
%% channel variable by the time the route win happens, so the clearing goes
%% to the channel too.
clear_injected() ->
    Call = kapps_call:set_custom_channel_vars([{<<"STIR-Attest">>, <<"A">>}
                                              ,{<<"STIR-Verstat">>, <<"TN-Validation-Passed">>}
                                              ,{<<"STIR-Inbound-Carrier">>, <<"true">>}
                                              ]
                                             ,call(<<"+15550000001">>, [], [])
                                             ),
    Cleared = cf_stir:clear(Call),
    ?assertEqual(<<"unknown">>, kapps_call:custom_channel_var(<<"STIR-Verstat">>, Cleared)),
    ?assertEqual('undefined', kapps_call:custom_channel_var(<<"STIR-Attest">>, Cleared)),
    ?assertEqual('undefined', kapps_call:custom_channel_var(<<"STIR-Inbound-Carrier">>, Cleared)),

    [Command] = flush(),
    ?assertEqual(<<"set">>, props:get_value(<<"Application-Name">>, Command)),
    ChannelVars = props:get_value(<<"Custom-Channel-Vars">>, Command),
    ?assertEqual(<<>>, kz_json:get_value(<<"STIR-Attest">>, ChannelVars)),
    ?assertEqual(<<>>, kz_json:get_value(<<"STIR-Inbound-Carrier">>, ChannelVars)).

%%------------------------------------------------------------------------------
%% With the stand-in
%%------------------------------------------------------------------------------

present_test_() ->
    {'setup'
    ,fun load_fake/0
    ,fun unload_fake/1
    ,fun(_) ->
             [{"nothing to verify: neither token nor Identity", fun no_evidence/0}
             ,{"verdict on the record, exported, and in the key-value store", fun verdict/0}
             ,{"verdict with an Identity header only", fun identity_only/0}
             ,{"existing exports are extended", fun exports_extended/0}
             ,{"verification turned off: call unchanged", fun disabled/0}
             ,{"error answer: call unchanged", fun error_answer/0}
             ,{"crash: call unchanged", fun crash/0}
             ,{"late answer: call unchanged, mailbox empty", {'timeout', 15, fun late/0}}
             ,{"answer of the wrong shape: call unchanged", fun wrong_shape/0}
             ,{"empty verdict: nothing set", fun empty_verdict/0}
             ,{"facts", fun facts/0}
             ]
     end
    }.

no_evidence() ->
    Call = call(<<"+15550000099">>, [], []),
    Verified = cf_stir:maybe_verify(Call),
    ?assertEqual(<<"unknown">>, kapps_call:custom_channel_var(<<"STIR-Verstat">>, Verified)),
    ?assertEqual('undefined', kapps_call:custom_channel_var(<<"STIR-Verdict-Source">>, Verified)),
    ?assertEqual([], flush()).

%% `kapps_call:set_custom_channel_vars/2' is what publishes the `set' in a
%% release; under test it only changes the record, so nothing is published
%% here and nothing is published twice there.
verdict() ->
    Call = call(<<"+15550000001">>, carrier_headers(), [{<<"identity">>, <<"jws">>}]),
    Verified = cf_stir:maybe_verify(Call),
    ?assertEqual(<<"TN-Validation-Passed">>, kapps_call:custom_channel_var(<<"STIR-Verstat">>, Verified)),
    ?assertEqual(<<"A">>, kapps_call:custom_channel_var(<<"STIR-Attest">>, Verified)),
    ?assertEqual(<<"carrier">>, kapps_call:custom_channel_var(<<"STIR-Verdict-Source">>, Verified)),

    %% the call came in from a carrier, so a leg forwarded back out can be
    %% attested for what arrived
    ?assertEqual(<<"true">>, kapps_call:custom_channel_var(<<"STIR-Inbound-Carrier">>, Verified)),
    ?assertEqual(<<"+15550000001">>, kapps_call:custom_channel_var(<<"STIR-Inbound-Caller">>, Verified)),

    Exports = kapps_call:custom_channel_var(<<"Call-Forward-Exports">>, Verified),
    ?assertEqual([<<"STIR-Attest">>
                 ,<<"STIR-Inbound-Caller">>
                 ,<<"STIR-Inbound-Carrier">>
                 ,<<"STIR-Verdict-Source">>
                 ,<<"STIR-Verstat">>
                 ]
                ,lists:sort(binary:split(Exports, <<"|">>, ['global']))
                ),

    Verdict = kapps_call:kvs_fetch('stir_verdict', Verified),
    ?assertEqual(<<"TN-Validation-Passed">>, props:get_value(<<"STIR-Verstat">>, Verdict)),
    ?assertEqual(<<"carrier">>, props:get_value(<<"STIR-Verdict-Source">>, Verdict)),

    ?assertEqual([], flush()),
    ?assertEqual({'message_queue_len', 0}, process_info(self(), 'message_queue_len')).

%% No SBC token: the call is not a carrier's, whatever we made of its
%% Identity header.
identity_only() ->
    Call = call(<<"+15550000050">>, [], [{<<"identity">>, <<"jws">>}]),
    Verified = cf_stir:maybe_verify(Call),
    ?assertEqual(<<"jws">>, kapps_call:custom_channel_var(<<"identity">>, Verified)),
    ?assertEqual('undefined', kapps_call:custom_channel_var(<<"STIR-Inbound-Carrier">>, Verified)),
    _ = flush().

exports_extended() ->
    Call = kapps_call:set_custom_channel_vars([{<<"Call-Forward-Exports">>, <<"Foo|STIR-Verstat">>}]
                                             ,call(<<"+15550000001">>, carrier_headers(), [])
                                             ),
    Verified = cf_stir:maybe_verify(Call),
    ?assertEqual(<<"Foo|STIR-Verstat|STIR-Attest|STIR-Verdict-Source|STIR-Inbound-Carrier|STIR-Inbound-Caller">>
                ,kapps_call:custom_channel_var(<<"Call-Forward-Exports">>, Verified)
                ),
    _ = flush(),
    ?assertEqual(<<"A|B|C">>, cf_stir:exports([<<"B">>, <<"C">>], kapps_call:set_custom_channel_vars([{<<"Call-Forward-Exports">>, <<"A|B">>}], Call))),
    ?assertEqual(<<"C">>, cf_stir:exports([<<"C">>], kapps_call:new())).

disabled() ->
    unchanged(<<"+15550000005">>).

error_answer() ->
    unchanged(<<"+15550000002">>).

crash() ->
    unchanged(<<"+15550000003">>).

late() ->
    Started = erlang:monotonic_time('millisecond'),
    unchanged(<<"+15550000004">>),
    Elapsed = erlang:monotonic_time('millisecond') - Started,
    %% the default deadline is 1500 ms plus 500 ms of grace
    ?assert(Elapsed >= 2000),
    ?assert(Elapsed < 2900),
    %% the stand-in would have answered at 3000 ms; the proxy is gone by now
    timer:sleep(1500),
    ?assertEqual({'message_queue_len', 0}, process_info(self(), 'message_queue_len')).

wrong_shape() ->
    unchanged(<<"+15550000006">>).

empty_verdict() ->
    unchanged(<<"+15550000007">>).

%% Nothing decided: `STIR-Verstat' is `unknown' and nothing else was
%% written or published.
unchanged(CallerNumber) ->
    Call = call(CallerNumber, carrier_headers(), [{<<"identity">>, <<"jws">>}]),
    Verified = cf_stir:maybe_verify(Call),
    ?assertEqual(<<"unknown">>, kapps_call:custom_channel_var(<<"STIR-Verstat">>, Verified)),
    ?assertEqual('undefined', kapps_call:custom_channel_var(<<"STIR-Verdict-Source">>, Verified)),
    ?assertEqual('undefined', kapps_call:custom_channel_var(<<"STIR-Inbound-Carrier">>, Verified)),
    ?assertEqual('undefined', kapps_call:custom_channel_var(<<"Call-Forward-Exports">>, Verified)),
    ?assertEqual([], flush()).

facts() ->
    Call = call(<<"+15550000050">>, carrier_headers(), [{<<"identity">>, <<"jws">>}]),
    Verified = cf_stir:maybe_verify(Call),
    Expected = [{<<"account_id">>, ?ACCOUNT_ID}
               ,{<<"trusted_type">>, <<"global_carrier">>}
               ,{<<"token">>, ?TOKEN}
               ,{<<"verstat">>, <<"TN-Validation-Passed-B">>}
               ,{<<"attest_indicator">>, <<"B">>}
               ,{<<"origination_id">>, <<"orig-1">>}
               ,{<<"identity">>, <<"jws">>}
               ,{<<"caller_number">>, <<"+15550000050">>}
               ,{<<"dialed_number">>, <<"+14155551212">>}
               ],
    [?assertEqual({Key, Value}, {Key, kapps_call:custom_channel_var(Key, Verified)}) || {Key, Value} <- Expected],
    _ = flush(),

    %% a call with a token but no carrier verdict and no Identity
    Bare = call(<<"+15550000051">>, [{<<"Token">>, ?TOKEN}, {<<"Trusted-Type">>, <<"endpoint">>}], []),
    Verified2 = cf_stir:maybe_verify(Bare),
    ?assertEqual(<<"endpoint">>, kapps_call:custom_channel_var(<<"trusted_type">>, Verified2)),
    ?assertEqual('undefined', kapps_call:custom_channel_var(<<"verstat">>, Verified2)),
    ?assertEqual('undefined', kapps_call:custom_channel_var(<<"identity">>, Verified2)),
    %% the SBC said this is not a carrier, so no inbound-carrier facts
    ?assertEqual('undefined', kapps_call:custom_channel_var(<<"STIR-Inbound-Carrier">>, Verified2)),
    _ = flush().

%%------------------------------------------------------------------------------
%% `verify_mode' async
%%------------------------------------------------------------------------------

async_test_() ->
    {'setup'
    ,fun() ->
             Hidden = load_fake(),
             meck:new('kapps_config', ['unstick', 'passthrough']),
             meck:expect('kapps_config', 'get_ne_binary'
                        ,fun(<<"stir">>, <<"verify_mode">>, _Default) -> <<"async">>;
                            (Category, Key, Default) -> meck:passthrough([Category, Key, Default])
                         end
                        ),
             Hidden
     end
    ,fun(Hidden) ->
             meck:unload('kapps_config'),
             unload_fake(Hidden)
     end
    ,fun(_) ->
             [{"async: the flow is not held up and the channel gets the verdict", fun async/0}]
     end
    }.

%% The flow starts at once with nothing but the clearing on the record; the
%% verdict reaches the channel when it is ready. There is no `cf_exe' here,
%% so the executer is not updated and that is not an error.
async() ->
    Call = call(<<"+15550000001">>, carrier_headers(), []),
    Verified = cf_stir:maybe_verify(Call),
    ?assertEqual(<<"unknown">>, kapps_call:custom_channel_var(<<"STIR-Verstat">>, Verified)),
    ?assertEqual('undefined', kapps_call:custom_channel_var(<<"STIR-Verdict-Source">>, Verified)),

    Command = await_publish(),
    ?assertEqual(<<"set">>, props:get_value(<<"Application-Name">>, Command)),
    ChannelVars = props:get_value(<<"Custom-Channel-Vars">>, Command),
    ?assertEqual(<<"TN-Validation-Passed">>, kz_json:get_value(<<"STIR-Verstat">>, ChannelVars)),
    ?assertEqual(<<"carrier">>, kz_json:get_value(<<"STIR-Verdict-Source">>, ChannelVars)),
    ?assertEqual(<<"true">>, kz_json:get_value(<<"STIR-Inbound-Carrier">>, ChannelVars)),
    ?assertEqual(<<"+15550000001">>, kz_json:get_value(<<"STIR-Inbound-Caller">>, ChannelVars)),
    ?assertNotEqual('undefined', kz_json:get_value(<<"Call-Forward-Exports">>, ChannelVars)),
    ?assertEqual([], flush()).

await_publish() ->
    receive {'published', Command} -> Command
    after 5000 -> erlang:error('no_verdict_on_the_channel')
    end.

%%------------------------------------------------------------------------------
%% Fixtures
%%------------------------------------------------------------------------------

carrier_headers() ->
    [{<<"Token">>, ?TOKEN}
    ,{<<"Trusted-Type">>, <<"global_carrier">>}
    ,{<<"Verstat">>, <<"TN-Validation-Passed-B">>}
    ,{<<"Attest">>, <<"B">>}
    ,{<<"Orig-ID">>, <<"orig-1">>}
    ].

%% A call as `cf_route_win' sees it, with the channel's set command
%% published to this process instead of a control queue.
call(CallerNumber, AuthHeaders, SipHeaders) ->
    Self = self(),
    RouteReq = kz_json:from_list_recursive(
                 [{<<"Call-ID">>, <<"call-1">>}
                 ,{<<"Call-Direction">>, <<"inbound">>}
                 ,{<<"Caller-ID-Name">>, <<"caller">>}
                 ,{<<"Caller-ID-Number">>, CallerNumber}
                 ,{<<"From">>, <<CallerNumber/binary, "@carrier.example">>}
                 ,{<<"To">>, <<"+14155551212@4a6863.sip.2600hz.local">>}
                 ,{<<"Request">>, <<"+14155551212@4a6863.sip.2600hz.local">>}
                   %% `Inception' is the route the call came in on,
                   %% `<number>@<realm>', not the word "offnet"
                 ,{<<"Custom-Channel-Vars">>, [{<<"Account-ID">>, ?ACCOUNT_ID}
                                              ,{<<"Inception">>, <<CallerNumber/binary, "@4a6863.sip.2600hz.local">>}
                                              ]}
                 ,{<<"Custom-AUTH-Headers">>, AuthHeaders}
                 ,{<<"Custom-SIP-Headers">>, SipHeaders}
                 ,{<<"Event-Category">>, <<"dialplan">>}
                 ,{<<"Event-Name">>, <<"route_req">>}
                 ,{<<"App-Name">>, <<"ecallmgr">>}
                 ,{<<"App-Version">>, <<"4.0.0">>}
                 ]),
    Call = kapps_call:from_route_req(RouteReq),
    kapps_call:set_custom_publish_function(fun(Command, _Call) -> Self ! {'published', Command}, 'ok' end, Call).

flush() ->
    flush([]).

flush(Acc) ->
    receive
        {'published', Command} -> flush([Command | Acc])
    after 0 -> lists:reverse(Acc)
    end.

%% The stand-in is loaded with the real application off the code path
%% (hide_stir/0). Should a real `stir@inbound' still be found, loading over
%% it and purging it afterwards would break every later test in the run, so
%% the run stops here instead.
load_fake() ->
    Hidden = hide_stir(),
    ?assertEqual('non_existing', code:where_is_file("stir@inbound.beam")),
    Forms = forms(?FAKE_SOURCE),
    {'ok', ?INBOUND, Binary} = compile:forms(Forms, ['return_errors']),
    {'module', ?INBOUND} = code:load_binary(?INBOUND, ?FAKE_FILE, Binary),
    Hidden.

unload_fake(Hidden) ->
    unload_fake(),
    restore_stir(Hidden).

%% applications/stir is built wherever the gleam binary is (CI's build job
%% installs it), and its ebin is then on the code path through ERL_LIBS. For
%% the length of a group that ebin is taken off the path and a copy of the
%% module loaded from it is unloaded, so that `absent' means absent and the
%% stand-in replaces nothing; restore_stir/1 puts the path back.
hide_stir() ->
    unload_fake(),
    case code:where_is_file("stir@inbound.beam") of
        'non_existing' -> 'undefined';
        Beam ->
            Ebin = filename:dirname(Beam),
            'true' = code:del_path(Ebin),
            _ = code:purge(?INBOUND),
            _ = code:delete(?INBOUND),
            _ = code:purge(?INBOUND),
            Ebin
    end.

restore_stir('undefined') -> 'ok';
restore_stir(Ebin) ->
    'true' = code:add_pathz(Ebin),
    'ok'.

%% Only ever the stand-in: `code:which/1' answers the filename it was
%% loaded under, which nothing on the code path can be.
unload_fake() ->
    case code:which(?INBOUND) of
        ?FAKE_FILE ->
            _ = code:purge(?INBOUND),
            _ = code:delete(?INBOUND),
            _ = code:purge(?INBOUND),
            'ok';
        _NotOurs -> 'ok'
    end.

forms(Source) ->
    {'ok', Tokens, _} = erl_scan:string(Source),
    [begin {'ok', Form} = erl_parse:parse_form(FormTokens), Form end
     || FormTokens <- split_forms(Tokens, [], [])
    ].

split_forms([], [], Forms) -> lists:reverse(Forms);
split_forms([{'dot', _}=Dot | Rest], Acc, Forms) ->
    split_forms(Rest, [], [lists:reverse([Dot | Acc]) | Forms]);
split_forms([Token | Rest], Acc, Forms) ->
    split_forms(Rest, [Token | Acc], Forms).
