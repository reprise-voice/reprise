%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2026, Vonix LLC
%%% @doc STIR/SHAKEN verdict on an inbound call.
%%%
%%% Run by the winning node before the callflow starts
%%% (`cf_route_win:bootstrap_callflow_executer/1'; trunkstore calls it after
%%% its route win) for **every** call it starts, not only for the ones that
%%% look like carrier calls. This module is the only writer of the `STIR-*'
%%% channel variables, and it begins by clearing them: a peer that put
%%% `X-ecallmgr_STIR-Verstat' in its INVITE would otherwise have its own
%%% verdict on the call. `STIR-Verstat' is left as `unknown' -- nothing was
%%% decided yet -- and the rest are removed. On an honest call nothing is
%%% cleared and nothing is published; when something did arrive, the
%%% clearing goes to the channel too, since the injected variables are on
%%% the channel and would otherwise reach the CDR.
%%%
%%% The Gleam application `stir' decides (`stir@inbound:verify/1',
%%% `doc/engineering/stir-shaken.md' §3.5a): the carrier's own verdict when
%%% the SBC classified the call as a carrier call and the resource trusts
%%% upstream, otherwise Kazoo's own check of the `Identity' header. This
%%% module gathers the facts, makes the call under one deadline, and puts
%%% the answer's `STIR-*' channel variables on the channel and on the call
%%% record, exported through a call forward. A carrier call also gets
%%% `STIR-Inbound-Carrier' and `STIR-Inbound-Caller', which
%%% `stepswitch_stir' reads back off the requestor's channel variables when
%%% the call is forwarded out again, and the whole verdict is kept in the
%%% call's key-value store under `stir_verdict'.
%%%
%%% Nothing here can stop a call: when the `stir' application is not
%%% loaded, when the call carries neither an SBC token nor an `Identity'
%%% header, when the verifier answers an error (`disabled' and `ignore' are
%%% the ordinary ones) or is late, or when anything raises, the call is
%%% left as the clearing left it. `verify_mode' `async' starts the flow at
%%% once and lets the verdict land on the channel, and on the running
%%% executer's copy of the call, when it is ready.
%%% @end
%%%-----------------------------------------------------------------------------
-module(cf_stir).

-export([maybe_verify/1]).

-ifdef(TEST).
-export([call/4
        ,exports/2
        ,clear/1
        ]).
-endif.

-include("callflow.hrl").

-define(INBOUND, 'stir@inbound').
-define(CONFIG_CAT, <<"stir">>).

%% The verifier's own deadline, and how much longer we wait for its answer.
-define(DEFAULT_TIMEOUT_MS, 1500).
-define(GRACE_MS, 500).

-define(EXPORTS, <<"Call-Forward-Exports">>).

-define(VERSTAT, <<"STIR-Verstat">>).
-define(INBOUND_CARRIER, <<"STIR-Inbound-Carrier">>).
-define(INBOUND_CALLER, <<"STIR-Inbound-Caller">>).
-define(VERDICT_SOURCE, <<"STIR-Verdict-Source">>).

%% Every channel variable this module owns. Nothing else may write them,
%% and whatever a call arrives with is cleared before a verdict is asked
%% for.
-define(STIR_CCVS, [?VERSTAT
                   ,<<"STIR-Attest">>
                   ,<<"STIR-Orig-ID">>
                   ,<<"STIR-Key-ID">>
                   ,<<"STIR-Identity">>
                   ,?VERDICT_SOURCE
                   ,<<"STIR-Revocation">>
                   ,<<"STIR-Reason">>
                   ,?INBOUND_CARRIER
                   ,?INBOUND_CALLER
                   ]).

%% `STIR-Verstat' while nothing has been decided. A verdict overwrites it;
%% a call nobody verified keeps it, so a CDR tells "not looked at" from
%% "looked at and found nothing".
-define(UNKNOWN, <<"unknown">>).

-define(VERDICT_KEY, 'stir_verdict').

%%------------------------------------------------------------------------------
%% @doc Put the STIR/SHAKEN verdict on the call, when there is one to get.
%% Always answers a call; never raises.
%% @end
%%------------------------------------------------------------------------------
-spec maybe_verify(kapps_call:call()) -> kapps_call:call().
maybe_verify(Call) ->
    Cleared = clear(Call),
    try maybe_verify_loaded(Cleared)
    catch
        _E:_R ->
            lager:debug("stir verification skipped: ~p:~p", [_E, _R]),
            Cleared
    end.

%%------------------------------------------------------------------------------
%% @doc Take every `STIR-*' channel variable the call arrived with off it,
%% and leave `STIR-Verstat' at `unknown'.
%%
%% Nothing legitimate sets these before this point: the verdict is written
%% here and nowhere else. A value on an inbound call is therefore either a
%% peer's injection through an `X-ecallmgr_STIR-*' header (which the SBC
%% strips, `configs/kamailio/kamailio/defs.cfg') or a stale variable from a
%% loopback leg, and neither may be believed. When there is something to
%% clear it is cleared on the channel as well as on the record, because the
%% injected value is a real channel variable by now; an honest call -- every
%% call, in practice -- publishes nothing.
%% @end
%%------------------------------------------------------------------------------
-spec clear(kapps_call:call()) -> kapps_call:call().
clear(Call) ->
    Cleared = case [Key || Key <- ?STIR_CCVS,
                           kapps_call:custom_channel_var(Key, Call) =/= 'undefined'
                   ]
              of
                  [] -> Call;
                  Present ->
                      lager:warning("call arrived with ~s set by something other than ~s, clearing"
                                   ,[kz_binary:join(Present, <<", ">>), ?MODULE]
                                   ),
                      kapps_call:remove_custom_channel_vars(Present, Call)
              end,
    kapps_call:insert_custom_channel_var(?VERSTAT, ?UNKNOWN, Cleared).

-spec maybe_verify_loaded(kapps_call:call()) -> kapps_call:call().
maybe_verify_loaded(Call) ->
    case code:ensure_loaded(?INBOUND) =:= {'module', ?INBOUND}
        andalso has_evidence(Call)
    of
        'false' -> Call;
        'true' -> verify(mode(), Call)
    end.

%% A call worth asking about carries the SBC's token (a trusted source,
%% carrier or not) or an Identity header.
-spec has_evidence(kapps_call:call()) -> boolean().
has_evidence(Call) ->
    auth_header(<<"Token">>, Call) =/= 'undefined'
        orelse identity(Call) =/= 'undefined'.

-spec verify(kz_term:ne_binary(), kapps_call:call()) -> kapps_call:call().
verify(<<"async">>, Call) ->
    Facts = facts(Call),
    Timeout = timeout(),
    _ = kz_process:spawn(fun() ->
                                 case call(?INBOUND, 'verify', [Facts], Timeout) of
                                     {'ok', Ccvs} -> set_channel(Ccvs, Call);
                                     {'error', _Reason} ->
                                         lager:debug("stir gave no verdict: ~p", [_Reason])
                                 end
                         end),
    Call;
verify(_Sync, Call) ->
    case call(?INBOUND, 'verify', [facts(Call)], timeout()) of
        {'ok', Ccvs} -> set_call(Ccvs, Call);
        {'error', _Reason} ->
            lager:debug("stir gave no verdict: ~p", [_Reason]),
            Call
    end.

-spec mode() -> kz_term:ne_binary().
mode() ->
    kapps_config:get_ne_binary(?CONFIG_CAT, <<"verify_mode">>, <<"sync">>).

-spec timeout() -> pos_integer().
timeout() ->
    kapps_config:get_integer(?CONFIG_CAT, <<"verify_timeout_ms">>, ?DEFAULT_TIMEOUT_MS) + ?GRACE_MS.

%%------------------------------------------------------------------------------
%% @doc The facts map for `stir@inbound:verify/1': every value a binary,
%% unknown facts left out. The `X-AUTH-*' stamps of the SBC arrive as
%% custom AUTH headers; the `Identity' header as a custom SIP header.
%% @end
%%------------------------------------------------------------------------------
-spec facts(kapps_call:call()) -> map().
facts(Call) ->
    maps:from_list(
      props:filter_undefined(
        [{<<"account_id">>, to_binary(kapps_call:account_id(Call))}
        ,{<<"trusted_type">>, auth_header(<<"Trusted-Type">>, Call)}
        ,{<<"token">>, auth_header(<<"Token">>, Call)}
        ,{<<"verstat">>, auth_header(<<"Verstat">>, Call)}
        ,{<<"attest_indicator">>, auth_header(<<"Attest">>, Call)}
        ,{<<"origination_id">>, auth_header(<<"Orig-ID">>, Call)}
        ,{<<"identity">>, identity(Call)}
        ,{<<"caller_number">>, to_binary(kapps_call:caller_id_number(Call))}
        ,{<<"dialed_number">>, to_binary(kapps_call:request_user(Call))}
        ])).

-spec auth_header(kz_term:ne_binary(), kapps_call:call()) -> kz_term:api_ne_binary().
auth_header(Name, Call) ->
    to_binary(kz_json:get_value(Name, kapps_call:custom_auth_headers(Call))).

-spec identity(kapps_call:call()) -> kz_term:api_ne_binary().
identity(Call) ->
    Headers = kapps_call:custom_sip_headers(Call),
    to_binary(kz_json:get_first_defined([<<"identity">>, <<"Identity">>], Headers)).

-spec to_binary(any()) -> kz_term:api_ne_binary().
to_binary('undefined') -> 'undefined';
to_binary(<<>>) -> 'undefined';
to_binary(Value) when is_binary(Value) -> Value;
to_binary(Value) ->
    try kz_term:to_binary(Value)
    catch _:_ -> 'undefined'
    end.

%%------------------------------------------------------------------------------
%% @doc The verdict onto the channel and the call record, and its names
%% into `Call-Forward-Exports' so a forwarded leg carries it.
%%
%% `kapps_call:set_custom_channel_vars/2' publishes the `set' itself
%% (`kapps_call.erl'), so the sync path does not publish one of its own.
%% @end
%%------------------------------------------------------------------------------
-spec set_call(any(), kapps_call:call()) -> kapps_call:call().
set_call(Ccvs, Call) ->
    case pairs(Ccvs, Call) of
        [] -> Call;
        Pairs ->
            kapps_call:kvs_store(?VERDICT_KEY
                                ,verdict(Ccvs)
                                ,kapps_call:set_custom_channel_vars(Pairs, Call)
                                )
    end.

%% The async path has no call record to hand back: the flow started without
%% it. The channel is set here, and the executer's own copy is updated in
%% place so that a forward decided later exports the verdict too.
-spec set_channel(any(), kapps_call:call()) -> 'ok'.
set_channel(Ccvs, Call) ->
    case pairs(Ccvs, Call) of
        [] -> 'ok';
        Pairs ->
            _ = kapps_call_command:set(kz_json:from_list(Pairs), Call),
            update_executer(Pairs, verdict(Ccvs), Call)
    end.

%% `cf_exe' applies the routines to whatever the call looks like now, so a
%% verdict that arrives late does not overwrite anything the flow changed
%% meanwhile. There is no executer behind a trunkstore call, and the one
%% behind a callflow may be gone by now; neither is an error.
-spec update_executer(kz_term:proplist(), any(), kapps_call:call()) -> 'ok'.
update_executer(Pairs, Verdict, Call) ->
    case kapps_call:kvs_fetch('cf_exe_pid', Call) of
        Pid when is_pid(Pid) ->
            Routines = [fun(C) -> kapps_call:kvs_store(?VERDICT_KEY, Verdict, C) end
                        | [fun(C) -> kapps_call:insert_custom_channel_var(Key, Value, C) end
                           || {Key, Value} <- Pairs
                          ]
                       ],
            try _ = cf_exe:update_call(Call, Routines), 'ok'
            catch
                _E:_R ->
                    lager:debug("stir verdict did not reach the executer: ~p:~p", [_E, _R]),
                    'ok'
            end;
        _NoExecuter -> 'ok'
    end.

%% The verdict as the Gleam side answered it, for the key-value store: a
%% map of the channel variables, whatever shape it came in.
-spec verdict(any()) -> kz_term:proplist().
verdict(Ccvs) -> to_proplist(Ccvs).

%%------------------------------------------------------------------------------
%% @doc The channel variables to set: the verdict's own, the two facts a
%% forwarded leg's signature needs when the call came from a carrier, and
%% the export list that carries all of them through a forward.
%% @end
%%------------------------------------------------------------------------------
-spec pairs(any(), kapps_call:call()) -> kz_term:proplist().
pairs(Ccvs, Call) ->
    case [{Key, Value}
          || {Key, Value} <- to_proplist(Ccvs),
             is_binary(Key),
             is_binary(Value)
         ]
    of
        [] -> [];
        Verdict ->
            Pairs = Verdict ++ inbound_facts(Verdict, Call),
            [{?EXPORTS, exports([Key || {Key, _} <- Pairs], Call)} | Pairs]
    end.

%% What `stepswitch_stir' needs off the requestor when this call is
%% forwarded back out to a carrier: that it came in from one, and the
%% number it came in from. `stir@inbound' only ever says `carrier' for a
%% call the SBC classified as a carrier's; a carrier that sent no verdict
%% of its own is verified by us (`kazoo'), so the SBC's own classification
%% is the fallback -- the same two facts `stir/inbound.gleam' reads.
-spec inbound_facts(kz_term:proplist(), kapps_call:call()) -> kz_term:proplist().
inbound_facts(Verdict, Call) ->
    case props:get_value(?VERDICT_SOURCE, Verdict) =:= <<"carrier">>
        orelse is_carrier(Call)
    of
        'false' -> [];
        'true' ->
            props:filter_undefined(
              [{?INBOUND_CARRIER, <<"true">>}
              ,{?INBOUND_CALLER, digits(kapps_call:caller_id_number(Call))}
              ])
    end.

%% The SBC's token is the proof that the call came from a peer in its
%% trusted table; the trusted type says which kind, and the two kinds that
%% are not a carrier are believed when they are given.
-spec is_carrier(kapps_call:call()) -> boolean().
is_carrier(Call) ->
    auth_header(<<"Token">>, Call) =/= 'undefined'
        andalso not lists:member(auth_header(<<"Trusted-Type">>, Call)
                                ,[<<"endpoint">>, <<"trusted_source">>]
                                ).

%% The caller id as a number and nothing else: a leading `+' and digits.
-spec digits(any()) -> kz_term:api_ne_binary().
digits(Number) ->
    case to_binary(Number) of
        'undefined' -> 'undefined';
        <<"+", Rest/binary>> -> prefixed(<<"+">>, only_digits(Rest));
        Binary -> prefixed(<<>>, only_digits(Binary))
    end.

-spec prefixed(binary(), binary()) -> kz_term:api_ne_binary().
prefixed(_Prefix, <<>>) -> 'undefined';
prefixed(Prefix, Digits) -> <<Prefix/binary, Digits/binary>>.

-spec only_digits(binary()) -> binary().
only_digits(Binary) ->
    << <<C>> || <<C>> <= Binary, C >= $0, C =< $9 >>.

%% `Call-Forward-Exports' is a `|'-separated list of CCV names that
%% `cf_resources' copies onto a forwarded leg.
-spec exports(kz_term:ne_binaries(), kapps_call:call()) -> kz_term:ne_binary().
exports(Keys, Call) ->
    Existing = case kapps_call:custom_channel_var(?EXPORTS, Call) of
                   <<_/binary>>=Exports -> binary:split(Exports, <<"|">>, ['global']);
                   _ -> []
               end,
    New = [Key || Key <- Keys, not lists:member(Key, Existing)],
    kz_binary:join([Name || Name <- Existing ++ New, Name =/= <<>>], <<"|">>).

%% The Gleam side answers maps; accept a JSON object too.
-spec to_proplist(any()) -> kz_term:proplist().
to_proplist(Map) when is_map(Map) -> maps:to_list(Map);
to_proplist(List) when is_list(List) -> List;
to_proplist(MaybeJObj) ->
    case kz_json:is_json_object(MaybeJObj) of
        'true' -> kz_json:to_proplist(MaybeJObj);
        'false' -> []
    end.

%%------------------------------------------------------------------------------
%% @doc Apply `M:F(A)' in a short-lived proxy process and wait at most
%% `Timeout' ms for its answer. After the timeout the proxy is killed and
%% its exit is awaited before returning, so no answer of its can arrive in
%% the caller's mailbox later. A proxy that crashes answers `{error, _}'.
%%
%% The proxy watches the caller as well: the work runs in a worker linked
%% to the proxy, so a caller that dies -- a channel torn down while the
%% verifier is still fetching a certificate -- takes both of them with it
%% instead of leaving an x5u fetch running for nobody.
%% @end
%%------------------------------------------------------------------------------
-spec call(module(), atom(), list(), timeout()) -> {'ok', any()} | {'error', any()}.
call(Module, Function, Args, Timeout) ->
    Caller = self(),
    Ref = make_ref(),
    {Pid, MRef} = kz_process:spawn_monitor(fun() -> proxy(Caller, Ref, Module, Function, Args) end
                                          ,[]
                                          ),
    receive
        {Ref, Result} ->
            erlang:demonitor(MRef, ['flush']),
            normalize(Result);
        {'DOWN', MRef, 'process', Pid, Reason} ->
            {'error', {'crashed', Reason}}
    after Timeout ->
            exit(Pid, 'kill'),
            receive {'DOWN', MRef, 'process', Pid, _} -> 'ok' end,
            receive {Ref, _Late} -> 'ok' after 0 -> 'ok' end,
            {'error', 'timeout'}
    end.

-spec proxy(pid(), reference(), module(), atom(), list()) -> 'ok'.
proxy(Caller, Ref, Module, Function, Args) ->
    Proxy = self(),
    CallerRef = erlang:monitor('process', Caller),
    WorkRef = make_ref(),
    %% linked, so killing this proxy kills the work with it
    {Worker, WorkerRef} = spawn_opt(fun() -> Proxy ! {WorkRef, erlang:apply(Module, Function, Args)} end
                                   ,['link', 'monitor']
                                   ),
    receive
        {WorkRef, Result} ->
            Caller ! {Ref, Result},
            'ok';
        {'DOWN', WorkerRef, 'process', Worker, Reason} ->
            erlang:demonitor(CallerRef, ['flush']),
            exit(Reason);
        {'DOWN', CallerRef, 'process', Caller, _Reason} ->
            %% the caller is gone; the answer has nowhere to go
            _ = unlink(Worker),
            exit(Worker, 'kill'),
            'ok'
    end.

-spec normalize(any()) -> {'ok', any()} | {'error', any()}.
normalize({'ok', _}=Ok) -> Ok;
normalize({'error', _}=Error) -> Error;
normalize(Other) -> {'error', {'unexpected', Other}}.
