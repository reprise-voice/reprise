%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2026, Vonix LLC
%%% @doc STIR/SHAKEN signing of carrier legs.
%%%
%%% Called once per offnet request from `stepswitch_resources:endpoints/2',
%%% after the gateway endpoints are built and before they are sorted. The
%%% Gleam application `stir' decides whether to sign (`stir@outbound:headers/1',
%%% `doc/engineering/stir-shaken.md' §3.2); this module gathers
%%% the facts, makes the call under a budget, and merges the answer into
%%% every endpoint whose resource has not opted out (`Stir-Sign' CCV, which
%%% is taken off the endpoint again once that decision is made -- it is a
%%% routing fact, not a channel variable FreeSWITCH should see).
%%%
%%% Fail open, in one place: when the `stir' application is not loaded, when
%%% the request is not a real call (`stepswitch_maintenance:process_number'
%%% builds an offnet request with no `Call-ID' to print the endpoints of a
%%% number; nothing is signed for it), when it answers an error, when it
%%% takes longer than the budget, or when anything here raises, the
%%% endpoints go out unsigned and the call proceeds. The call is made from a
%%% short-lived proxy process so that a late reply can never land in the
%%% stepswitch worker's mailbox.
%%%
%%% Kazoo alone decides the `Identity' header of a carrier leg. The
%%% signer's answer, a passthrough included, is not put among the endpoint's
%%% custom SIP headers but under a private key of its own (`Stir-Identity').
%%% When `stepswitch_util:format_endpoints/4' builds the leg's headers it
%%% takes that key off (`take_own_identity/1'), merges the request's headers
%%% in, runs the resource's formatters, then drops every `Identity' left
%%% among them, in any case and from wherever it came (the request -- a
%%% trunk's arrives there as `identity' --, the resource or gateway, another
%%% endpoint builder), and writes the signer's back as the only one
%%% (`put_own_identity/2'). A leg this module did not sign, or never saw,
%%% goes out with no `Identity' at all. The private key never reaches
%%% ecallmgr; a leg that somehow skipped that formatting would carry it as
%%% a key ecallmgr does not know, and merely go out unsigned.
%%%
%%% For operators: a resource formatter that strips `Identity', or the whole
%%% of `Custom-SIP-Headers', no longer takes the signed `Identity' off a
%%% carrier leg, since it is written after the formatters. To keep
%%% `Identity' off a carrier, set the resource's `stir.sign' to `false'.
%%% @end
%%%-----------------------------------------------------------------------------
-module(stepswitch_stir).

-export([maybe_sign/3
        ,drop_foreign_identity/2
        ,take_own_identity/1
        ,put_own_identity/2
        ]).

-ifdef(TEST).
-export([call/4]).
-endif.

-include("stepswitch.hrl").

-define(OUTBOUND, 'stir@outbound').

%% The signer's own budget, and how long we wait for the whole answer.
-define(BUDGET_MS, 500).
-define(WAIT_MS, 600).

-define(CCVS, <<"Custom-Channel-Vars">>).
-define(CSHS, <<"Custom-SIP-Headers">>).
-define(STIR_SIGN, <<"Stir-Sign">>).
-define(IDENTITY, <<"Identity">>).
%% where the signer's `Identity' waits between `maybe_sign/3' and the
%% formatting of the leg's headers
-define(OWN_IDENTITY, <<"Stir-Identity">>).

%%------------------------------------------------------------------------------
%% @doc Sign the carrier legs of one offnet request, when the signer says so.
%% Always answers a list of endpoints; never raises.
%% @end
%%------------------------------------------------------------------------------
-spec maybe_sign(kz_term:ne_binary(), kapi_offnet_resource:req(), kz_json:objects()) ->
          kz_json:objects().
maybe_sign(_Number, _OffnetJObj, []) -> [];
maybe_sign(Number, OffnetJObj, Endpoints) ->
    Signed = try maybe_sign_loaded(Number, OffnetJObj, Endpoints)
             catch
                 _E:_R ->
                     lager:debug("stir signing skipped, legs go out unsigned: ~p:~p", [_E, _R]),
                     Endpoints
             end,
    [strip_stir_sign(Endpoint) || Endpoint <- Signed].

-spec maybe_sign_loaded(kz_term:ne_binary(), kapi_offnet_resource:req(), kz_json:objects()) ->
          kz_json:objects().
maybe_sign_loaded(Number, OffnetJObj, Endpoints) ->
    case code:ensure_loaded(?OUTBOUND) of
        {'module', ?OUTBOUND} -> maybe_sign_request(Number, OffnetJObj, Endpoints);
        {'error', _Why} ->
            lager:debug("stir application not loaded (~p), legs go out unsigned", [_Why]),
            Endpoints
    end.

%% Every offnet request of a real call carries the call's id.
%% `stepswitch_maintenance:process_number/1,2' builds one out of a `To-DID'
%% and an account id alone to print what a number would route to; signing
%% that would burn a signature (and an `origid') on a call that does not
%% exist.
-spec maybe_sign_request(kz_term:ne_binary(), kapi_offnet_resource:req(), kz_json:objects()) ->
          kz_json:objects().
maybe_sign_request(Number, OffnetJObj, Endpoints) ->
    case kapi_offnet_resource:call_id(OffnetJObj) of
        'undefined' ->
            lager:debug("offnet request for ~s has no call id, not a call to sign", [Number]),
            Endpoints;
        _CallId -> sign(Number, OffnetJObj, Endpoints)
    end.

-spec sign(kz_term:ne_binary(), kapi_offnet_resource:req(), kz_json:objects()) ->
          kz_json:objects().
sign(Number, OffnetJObj, Endpoints) ->
    Facts = facts(Number, OffnetJObj, Endpoints),
    case call(?OUTBOUND, 'headers', [Facts], ?WAIT_MS) of
        {'ok', Answer} ->
            lager:debug("stir answered for ~s, merging into ~b endpoint(s)", [Number, length(Endpoints)]),
            [merge_endpoint(Answer, Endpoint) || Endpoint <- Endpoints];
        {'error', _Reason} ->
            lager:debug("stir did not sign the legs to ~s: ~p", [Number, _Reason]),
            Endpoints
    end.

%%------------------------------------------------------------------------------
%% @doc The facts map for `stir@outbound:headers/1': every value a binary,
%% booleans as `true'/`false', unknown facts left out.
%% @end
%%------------------------------------------------------------------------------
-spec facts(kz_term:ne_binary(), kapi_offnet_resource:req(), kz_json:objects()) -> map().
facts(Number, OffnetJObj, Endpoints) ->
    Requestor = kapi_offnet_resource:requestor_custom_channel_vars(OffnetJObj, kz_json:new()),
    maps:from_list(
      props:filter_undefined(
        [{<<"account_id">>, to_binary(kapi_offnet_resource:account_id(OffnetJObj))}
        ,{<<"orig_number">>, orig_number(OffnetJObj)}
        ,{<<"dest_number">>, to_binary(Number)}
        ,{<<"inception">>, inception(OffnetJObj, Requestor)}
        ,{<<"call_forward">>, to_boolean(kz_json:get_value(<<"Call-Forward">>, Requestor))}
        ,{<<"retain_cid">>, to_boolean(kz_json:get_value(<<"Retain-CID">>, Requestor))}
        ,{<<"privacy_hide_number">>, privacy_hide_number(OffnetJObj, Endpoints)}
        ,{<<"emergency">>, emergency(Endpoints)}
        ,{<<"inbound_verstat">>, to_binary(kz_json:get_value(<<"STIR-Verstat">>, Requestor))}
        ,{<<"inbound_attest">>, to_binary(kz_json:get_value(<<"STIR-Attest">>, Requestor))}
        ,{<<"inbound_carrier">>, to_boolean(kz_json:get_value(<<"STIR-Inbound-Carrier">>, Requestor))}
        ,{<<"inbound_caller">>, to_binary(kz_json:get_value(<<"STIR-Inbound-Caller">>, Requestor))}
        ,{<<"inbound_identity">>, to_binary(kapi_offnet_resource:requestor_custom_sip_header(OffnetJObj, <<"identity">>))}
        ,{<<"resource_id">>, resource_id(Endpoints)}
        ,{<<"resource_sign">>, resource_sign(Endpoints)}
        ,{<<"budget_ms">>, kz_term:to_binary(?BUDGET_MS)}
        ])).

%%------------------------------------------------------------------------------
%% @doc The number that will be on the wire, computed the way
%% `stepswitch_bridge' will compute it a moment from now: the request's
%% outbound caller id, unless an asserted identity overrides it or
%% `should_enforce_account_cid' replaces it with the account's external
%% caller id (`stepswitch_bridge:maybe_override_asserted_identity/2'). The
%% PASSporT's `orig.tn' has to be what the P-Asserted-Identity carries, or
%% the terminating carrier's own check fails it.
%%
%% Emergency legs are not signed at all: their caller id is chosen later
%% still, from the account's emergency numbers.
%% @end
%%------------------------------------------------------------------------------
-spec orig_number(kapi_offnet_resource:req()) -> kz_term:api_ne_binary().
orig_number(OffnetJObj) ->
    Number = stepswitch_bridge:bridge_outbound_cid_number(OffnetJObj),
    Name = stepswitch_bridge:bridge_outbound_cid_name(OffnetJObj),
    try stepswitch_bridge:maybe_override_asserted_identity(OffnetJObj, {'false', Number, Name}) of
        {'undefined', _Name} -> to_binary(Number);
        {Asserted, _Name} -> to_binary(Asserted)
    catch
        _E:_R ->
            lager:debug("could not resolve the asserted caller id (~p:~p), signing the outbound one", [_E, _R]),
            to_binary(Number)
    end.

%% The gateway endpoints already carry the answer: `Privacy-Hide-Number' on
%% each of them is the gateway's own flag or the request's or the
%% requestor's (`stepswitch_resources:gateway_to_endpoint/3'). A leg whose
%% number is hidden is signed for the anonymous number, so one hidden leg
%% among them is enough to ask about.
-spec privacy_hide_number(kapi_offnet_resource:req(), kz_json:objects()) -> kz_term:api_ne_binary().
privacy_hide_number(OffnetJObj, Endpoints) ->
    to_boolean(lists:any(fun(Endpoint) -> kz_json:is_true(<<"Privacy-Hide-Number">>, Endpoint) end
                        ,Endpoints
                        )
               orelse kz_privacy:should_hide_number(OffnetJObj)
              ).

%% One signature serves every leg of the request, so the resource facts are
%% given only when the legs agree: the resource id when all legs belong to
%% one resource, and the opt-out only when every leg's resource opted out
%% (a mixed set is left to the per-endpoint merge).
-spec resource_id(kz_json:objects()) -> kz_term:api_ne_binary().
resource_id(Endpoints) ->
    case lists:usort([kz_json:get_ne_binary_value([?CCVS, <<"Resource-ID">>], Endpoint)
                      || Endpoint <- Endpoints
                     ])
    of
        [<<_/binary>>=ResourceId] -> ResourceId;
        _Several -> 'undefined'
    end.

-spec resource_sign(kz_json:objects()) -> kz_term:api_ne_binary().
resource_sign(Endpoints) ->
    case lists:all(fun(Endpoint) -> kz_term:is_false(kz_json:get_value([?CCVS, ?STIR_SIGN], Endpoint)) end
                  ,Endpoints
                  )
    of
        'true' -> <<"false">>;
        'false' -> 'undefined'
    end.

%% Kazoo's `Inception' is not a word but a route: the request the call came
%% in on, `<number>@<realm>' (`kz_directory_resource:set_inception/1',
%% `cf_resources:get_inception/1'). Its presence is what the attestation
%% policy means by an offnet inception, so that is what is sent.
-spec inception(kapi_offnet_resource:req(), kz_json:object()) -> kz_term:api_ne_binary().
inception(OffnetJObj, Requestor) ->
    case kz_json:get_ne_binary_value(<<"Inception">>, OffnetJObj) of
        'undefined' ->
            case kz_json:get_ne_binary_value(<<"Inception">>, Requestor) of
                'undefined' -> 'undefined';
                _Route -> <<"offnet">>
            end;
        _Route -> <<"offnet">>
    end.

%% `true' when any leg is an emergency leg; left out otherwise, so the signer
%% treats a missing key as "not emergency".
-spec emergency(kz_json:objects()) -> kz_term:api_ne_binary().
emergency(Endpoints) ->
    case lists:any(fun(Endpoint) -> kz_json:is_true([?CCVS, <<"Emergency-Resource">>], Endpoint) end
                  ,Endpoints
                  )
    of
        'true' -> <<"true">>;
        'false' -> 'undefined'
    end.

-spec to_boolean(any()) -> kz_term:api_ne_binary().
to_boolean('undefined') -> 'undefined';
to_boolean(Value) ->
    case kz_term:is_true(Value) of
        'true' -> <<"true">>;
        'false' -> <<"false">>
    end.

-spec to_binary(any()) -> kz_term:api_ne_binary().
to_binary('undefined') -> 'undefined';
to_binary(<<>>) -> 'undefined';
to_binary(Value) when is_binary(Value) -> Value;
to_binary(Value) ->
    try kz_term:to_binary(Value)
    catch _:_ -> 'undefined'
    end.

%%------------------------------------------------------------------------------
%% @doc Merge the signer's answer into one endpoint. A resource that opted
%% out (`Stir-Sign' false) keeps its endpoint as it was. The answer is the
%% map of `stir@outbound': `Identity' goes under the endpoint's private
%% `Stir-Identity' key (see the module doc), `Custom-Channel-Vars' merge into the endpoint's, and
%% `Exclude-Outgoing-Extra-Header' goes to the endpoint's top level where
%% `ecallmgr_fs_xml' turns it into a channel variable; it is what keeps
%% FreeSWITCH from sending the `Identity' it places itself a second time
%% as an extra header. An empty answer for either key is left off: the
%% bridge endpoint definition rejects an empty exclusion, and an endpoint
%% that fails it is dropped from the bridge. Anything else in the answer
%% is ignored. A passthrough answer has the same shape as a signed
%% one -- the inbound `Identity' as the header to send -- so there is
%% nothing here that tells the two apart.
%% @end
%%------------------------------------------------------------------------------
-spec merge_endpoint(any(), kz_json:object()) -> kz_json:object().
merge_endpoint(Answer, Endpoint) ->
    case kz_term:is_false(kz_json:get_value([?CCVS, ?STIR_SIGN], Endpoint)) of
        'true' -> Endpoint;
        'false' -> lists:foldl(fun merge_answer_key/2, Endpoint, to_proplist(Answer))
    end.

%% `Stir-Sign' told this module which legs to leave alone; nothing past it
%% has any use for it, and it would otherwise reach FreeSWITCH as a channel
%% variable and the CDR as a column.
-spec strip_stir_sign(kz_json:object()) -> kz_json:object().
strip_stir_sign(Endpoint) ->
    case kz_json:get_json_value(?CCVS, Endpoint) of
        'undefined' -> Endpoint;
        CCVs -> kz_json:set_value(?CCVS, kz_json:delete_key(?STIR_SIGN, CCVs), Endpoint)
    end.

-spec merge_answer_key({any(), any()}, kz_json:object()) -> kz_json:object().
merge_answer_key({?IDENTITY, Identity}, Endpoint) when is_binary(Identity), Identity =/= <<>> ->
    %% not among the custom SIP headers, where it could not be told from a
    %% foreign one
    kz_json:set_value(?OWN_IDENTITY, Identity, Endpoint);
merge_answer_key({<<"Custom-Channel-Vars">>, CCVs}, Endpoint) ->
    Existing = kz_json:get_json_value(?CCVS, Endpoint, kz_json:new()),
    kz_json:set_value(?CCVS, kz_json:set_values(to_proplist(CCVs), Existing), Endpoint);
merge_answer_key({<<"Exclude-Outgoing-Extra-Header">>=Key, Value}, Endpoint) when is_binary(Value), Value =/= <<>> ->
    kz_json:set_value(Key, Value, Endpoint);
merge_answer_key({_Key, _Value}, Endpoint) ->
    Endpoint.

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
%% @doc Drop every `Identity' header, in any case, from a set of custom SIP
%% headers bound for a carrier leg, naming where it came from in the log.
%% Anything that is not a JSON object is answered as it came.
%% @end
%%------------------------------------------------------------------------------
-spec drop_foreign_identity(kz_json:api_json_term(), kz_term:ne_binary()) -> kz_json:api_json_term().
drop_foreign_identity(Headers, Source) ->
    case kz_json:is_json_object(Headers) of
        'true' ->
            lists:foldl(fun(Key, Acc) ->
                                lager:info("dropping the ~s header from ~s, Kazoo alone decides the Identity on a carrier leg"
                                          ,[Key, Source]
                                          ),
                                kz_json:delete_key(Key, Acc)
                        end
                       ,Headers
                       ,identity_keys(Headers)
                       );
        'false' -> Headers
    end.

%%------------------------------------------------------------------------------
%% @doc Take the signer's `Identity' off an endpoint whose custom SIP headers
%% are about to be merged and formatted: answers it, or `undefined' for a
%% leg `maybe_sign/3' did not sign or never saw, and the endpoint without
%% the private key. The key comes off before the formatters run, since they
%% match the endpoint's top-level keys by name as well as its headers.
%% @end
%%------------------------------------------------------------------------------
-spec take_own_identity(kz_json:object()) -> {kz_term:api_ne_binary(), kz_json:object()}.
take_own_identity(Endpoint) ->
    {kz_json:get_ne_binary_value(?OWN_IDENTITY, Endpoint)
    ,kz_json:delete_key(?OWN_IDENTITY, Endpoint)
    }.

%%------------------------------------------------------------------------------
%% @doc The header merge and the resource formatters are done: every
%% `Identity' among the leg's custom SIP headers now is foreign (ours was
%% taken off by `take_own_identity/1') and is dropped, and `Own', when
%% there is one, is written as the only one. A leg left with no headers has
%% the key taken off.
%% @end
%%------------------------------------------------------------------------------
-spec put_own_identity(kz_term:api_ne_binary(), kz_json:object()) -> kz_json:object().
put_own_identity(Own, Endpoint) ->
    Headers = drop_foreign_identity(kz_json:get_json_value(?CSHS, Endpoint, kz_json:new())
                                   ,<<"the request or the resource">>
                                   ),
    set_sip_headers(maybe_set_identity(Own, Headers), Endpoint).

%% Spelled `Identity', a name the exclusion `merge_answer_key/2' put on the
%% same leg matches (`^sip_h_[Ii]dentity$'); every other spelling is gone.
-spec maybe_set_identity(kz_term:api_ne_binary(), kz_json:object()) -> kz_json:object().
maybe_set_identity('undefined', Headers) -> Headers;
maybe_set_identity(Own, Headers) -> kz_json:set_value(?IDENTITY, Own, Headers).

-spec set_sip_headers(kz_json:object(), kz_json:object()) -> kz_json:object().
set_sip_headers(Headers, Endpoint) ->
    case kz_json:is_empty(Headers) of
        'true' -> kz_json:delete_key(?CSHS, Endpoint);
        'false' -> kz_json:set_value(?CSHS, Headers, Endpoint)
    end.

%% FreeSWITCH variable names are case-insensitive, so `identity' and
%% `IDENTITY' are the same header as `Identity' on the wire.
-spec identity_keys(kz_json:object()) -> kz_json:keys().
identity_keys(Headers) ->
    [Key || Key <- kz_json:get_keys(Headers),
            is_binary(Key),
            kz_term:to_lower_binary(Key) =:= <<"identity">>
    ].

%%------------------------------------------------------------------------------
%% @doc Apply `M:F(A)' in a short-lived proxy process and wait at most
%% `Timeout' ms for its answer. After the timeout the proxy is killed and
%% its exit is awaited before returning, so no answer of its can arrive in
%% the caller's mailbox later. A proxy that crashes answers `{error, _}'.
%%
%% The proxy watches the caller as well: the work runs in a worker linked
%% to the proxy, so a stepswitch worker that dies while the signer is still
%% reading a key takes both of them with it instead of leaving the work
%% running for nobody.
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
