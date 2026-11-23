%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2026, Vonix LLC
%%% @doc The Erlang side of `kazoo/call': the channel and the commands sent to
%%% it.
%%%
%%% This Source Code Form is subject to the terms of the Mozilla Public
%%% License, v. 2.0. If a copy of the MPL was not distributed with this
%%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%%
%%% A `kapps_call' record cannot be read in Gleam: it is a record, and a
%%% gleam-compiled .erl file has no include path to `kazoo_call/src'. So the
%%% call crosses the boundary as an opaque term and every read of it happens
%%% here, through `kapps_call''s own accessors.
%%%
%%% Outside a release there is no `kapps_call' at all, so a call is instead
%%% the map `kapps_call:to_json/1' would have produced, wrapped in
%%% `?FAKE(Map)'. The accessors read the same keys from it and the commands
%%% are no-ops, which is what lets the accessor tests run under `gleam test'.
%%% @end
%%%-----------------------------------------------------------------------------
-module(kazoo_gleam_call_ffi).

-export([new/0
        ,from_json/1
        ,to_map/1
        ,is_call/1
        ,get/2
        ,set_control_queue/2
        ,set_controller_queue/2
        ,custom_channel_var/2
        ,custom_channel_vars/1
        ,set_custom_channel_vars/2
        ,kvs_store/3
        ,kvs_fetch/2
        ,capture_group/1
        ,answer/1
        ,answer_now/1
        ,hangup/1
        ,unbridge/1
        ,hold/2
        ,hold_queued/2
        ,flush/1
        ,park/1
        ,execute_extension/2
        ,play/2
        ,prompt/2
        ,prompt_and_wait/2
        ,say/5
        ,audio_macro/2
        ,audio_macro_interrupting/2
        ,bridge/6
        ,bridge_interrupting/5
        ,wait_for_bridge/2
        ,record_call/4
        ,start_recording/3
        ,set_channel_vars/3
        ,receive_event/1
        ,relay_event/2
        ,wait_for_hangup/1
        ,wait_for_dtmf/1
        ,collect_digits/3
        ,prompt_and_collect_digits/6
        ,media_path/2
        ,prompt_path/3
        ]).

%% Test support. See `kazoo/testing/channel'.
-export([note/2
        ,record/0
        ,sent/0
        ,collect_answers/1
        ,play_results/1
        ]).

%% A call outside a release: the JSON form of the record and nothing else.
-define(FAKE(Map), {'kazoo_gleam_call', Map}).

-type call() :: any().
-export_type([call/0]).

%%%=============================================================================
%%% The call itself
%%%=============================================================================

%% @doc An empty call, which is what a test and a synthetic route win start
%% from.
-spec new() -> call().
new() ->
    case loaded('kapps_call') of
        'false' -> ?FAKE(#{});
        'true' -> kapps_call:new()
    end.

%% @doc A call from the JSON form `kapps_call:to_json/1' writes, which is what
%% the route win, an AMQP message and a stored document all carry.
-spec from_json(binary()) -> call().
from_json(Json) ->
    Map = decode_map(Json),
    case loaded('kapps_call') of
        'false' -> ?FAKE(Map);
        'true' -> kapps_call:from_json(kz_json:from_map(Map))
    end.

%% @doc The call back as a map, for a message, a document or a log line.
-spec to_map(call()) -> map().
to_map(?FAKE(Map)) -> Map;
to_map(Call) ->
    case loaded('kapps_call') of
        'false' -> #{};
        'true' -> kz_json:to_map(kapps_call:to_json(Call))
    end.

-spec is_call(call()) -> boolean().
is_call(?FAKE(_Map)) -> 'true';
is_call(Call) ->
    loaded('kapps_call')
        andalso kapps_call:is_call(Call).

%%%=============================================================================
%%% Accessors
%%%
%%% One table instead of thirty near-identical functions: the field name Gleam
%%% asks for, the `kapps_call' accessor that answers it, and the key the same
%%% value has in the JSON form, which is what the degraded path reads.
%%%=============================================================================

-spec get(call(), binary()) -> {'ok', binary()} | {'error', 'nil'}.
get(Call, Field) ->
    case field(Field) of
        'undefined' -> {'error', 'nil'};
        {Function, Key} -> read(Call, Function, Key)
    end.

-spec field(binary()) -> 'undefined' | {atom(), binary()}.
field(<<"call_id">>) -> {'call_id', <<"Call-ID">>};
field(<<"other_leg_call_id">>) -> {'other_leg_call_id', <<"Other-Leg-Call-ID">>};
field(<<"account_id">>) -> {'account_id', <<"Account-ID">>};
field(<<"account_db">>) -> {'account_db', <<"Account-DB">>};
field(<<"account_realm">>) -> {'account_realm', <<"Account-Realm">>};
field(<<"owner_id">>) -> {'owner_id', <<"Owner-ID">>};
field(<<"authorizing_id">>) -> {'authorizing_id', <<"Authorizing-ID">>};
field(<<"authorizing_type">>) -> {'authorizing_type', <<"Authorizing-Type">>};
field(<<"fetch_id">>) -> {'fetch_id', <<"Fetch-ID">>};
field(<<"control_queue">>) -> {'control_queue', <<"Control-Queue">>};
field(<<"controller_queue">>) -> {'controller_queue', <<"Controller-Queue">>};
field(<<"caller_id_name">>) -> {'caller_id_name', <<"Caller-ID-Name">>};
field(<<"caller_id_number">>) -> {'caller_id_number', <<"Caller-ID-Number">>};
field(<<"callee_id_name">>) -> {'callee_id_name', <<"Callee-ID-Name">>};
field(<<"callee_id_number">>) -> {'callee_id_number', <<"Callee-ID-Number">>};
field(<<"request">>) -> {'request', <<"Request">>};
field(<<"request_user">>) -> {'request_user', <<"Request-User">>};
field(<<"request_realm">>) -> {'request_realm', <<"Request-Realm">>};
field(<<"from">>) -> {'from', <<"From">>};
field(<<"from_user">>) -> {'from_user', <<"From-User">>};
field(<<"from_realm">>) -> {'from_realm', <<"From-Realm">>};
field(<<"to">>) -> {'to', <<"To">>};
field(<<"to_user">>) -> {'to_user', <<"To-User">>};
field(<<"to_realm">>) -> {'to_realm', <<"To-Realm">>};
field(<<"inception">>) -> {'inception', <<"Inception">>};
field(<<"language">>) -> {'language', <<"Language">>};
field(<<"direction">>) -> {'direction', <<"Call-Direction">>};
field(<<"switch_nodename">>) -> {'switch_nodename', <<"Switch-Nodename">>};
field(<<"resource_type">>) -> {'resource_type', <<"Resource-Type">>};
field(_Unknown) -> 'undefined'.

-spec read(call(), atom(), binary()) -> {'ok', binary()} | {'error', 'nil'}.
read(?FAKE(Map), _Function, Key) ->
    present(maps:get(Key, Map, 'undefined'));
read(Call, Function, _Key) ->
    case loaded('kapps_call') of
        'false' -> {'error', 'nil'};
        'true' ->
            try kapps_call:Function(Call) of
                Value -> present(Value)
            catch
                _E:_R -> {'error', 'nil'}
            end
    end.

%% @doc A value Kazoo may leave undefined, as the `Option' Gleam reads. An
%% empty binary is absent too: `kapps_call' returns one for several fields
%% that were never set.
-spec present(any()) -> {'ok', binary()} | {'error', 'nil'}.
present(<<>>) -> {'error', 'nil'};
present(Value) when is_binary(Value) -> {'ok', Value};
present(Value) when is_atom(Value)
                    andalso Value =/= 'undefined' ->
    {'ok', atom_to_binary(Value, 'utf8')};
present(_Undefined) -> {'error', 'nil'}.

-spec set_control_queue(call(), binary()) -> call().
set_control_queue(?FAKE(Map), Queue) ->
    ?FAKE(Map#{<<"Control-Queue">> => Queue});
set_control_queue(Call, Queue) ->
    case loaded('kapps_call') of
        'false' -> Call;
        'true' -> kapps_call:set_control_queue(Queue, Call)
    end.

-spec set_controller_queue(call(), binary()) -> call().
set_controller_queue(?FAKE(Map), Queue) ->
    ?FAKE(Map#{<<"Controller-Queue">> => Queue});
set_controller_queue(Call, Queue) ->
    case loaded('kapps_call') of
        'false' -> Call;
        'true' -> kapps_call:set_controller_queue(Queue, Call)
    end.

%%%=============================================================================
%%% Channel variables and the key-value store
%%%=============================================================================

-spec custom_channel_var(call(), binary()) -> {'ok', any()} | {'error', 'nil'}.
custom_channel_var(?FAKE(Map), Key) ->
    CCVs = maps:get(<<"Custom-Channel-Vars">>, Map, #{}),
    defined(maps:get(Key, CCVs, 'undefined'));
custom_channel_var(Call, Key) ->
    case loaded('kapps_call') of
        'false' -> {'error', 'nil'};
        'true' -> defined(kapps_call:custom_channel_var(Key, Call))
    end.

-spec defined(any()) -> {'ok', any()} | {'error', 'nil'}.
defined('undefined') -> {'error', 'nil'};
defined(Value) -> {'ok', Value}.

-spec custom_channel_vars(call()) -> map().
custom_channel_vars(?FAKE(Map)) ->
    maps:get(<<"Custom-Channel-Vars">>, Map, #{});
custom_channel_vars(Call) ->
    case loaded('kapps_call') of
        'false' -> #{};
        'true' -> kz_json:to_map(kapps_call:custom_channel_vars(Call))
    end.

%% @doc Set several channel variables at once on the call record. This does
%% not reach the channel; `set_channel_vars/3' is the command that does.
-spec set_custom_channel_vars(call(), binary()) -> call().
set_custom_channel_vars(?FAKE(Map), Json) ->
    CCVs = maps:get(<<"Custom-Channel-Vars">>, Map, #{}),
    ?FAKE(Map#{<<"Custom-Channel-Vars">> => maps:merge(CCVs, decode_map(Json))});
set_custom_channel_vars(Call, Json) ->
    case loaded('kapps_call') of
        'false' -> Call;
        'true' -> kapps_call:set_custom_channel_vars(maps:to_list(decode_map(Json)), Call)
    end.

%% @doc The key-value store travels with the call and, unlike a channel
%% variable, never reaches the channel. Keys from Gleam are binaries; the
%% callflow's own keys are atoms, so the two cannot collide.
-spec kvs_store(call(), binary(), binary()) -> call().
kvs_store(?FAKE(Map), Key, Json) ->
    KVS = maps:get(<<"Key-Value-Store">>, Map, #{}),
    ?FAKE(Map#{<<"Key-Value-Store">> => KVS#{Key => json:decode(Json)}});
kvs_store(Call, Key, Json) ->
    case loaded('kapps_call') of
        'false' -> Call;
        'true' -> kapps_call:kvs_store(Key, decode_value(Json), Call)
    end.

-spec kvs_fetch(call(), binary()) -> {'ok', any()} | {'error', 'nil'}.
kvs_fetch(?FAKE(Map), Key) ->
    KVS = maps:get(<<"Key-Value-Store">>, Map, #{}),
    defined(maps:get(Key, KVS, 'undefined'));
kvs_fetch(Call, Key) ->
    case loaded('kapps_call') of
        'false' -> {'error', 'nil'};
        'true' -> defined(to_map_value(kapps_call:kvs_fetch(Key, Call)))
    end.

%% @doc What the callflow's number pattern captured. `cf_route_req' stores it
%% under the atom `cf_capture_group', which a binary key from Gleam cannot
%% name. Outside a release the fake keeps it under the binary, which is where
%% `kvs_store/3' puts it.
-spec capture_group(call()) -> {'ok', binary()} | {'error', 'nil'}.
capture_group(?FAKE(Map)) ->
    KVS = maps:get(<<"Key-Value-Store">>, Map, #{}),
    present(maps:get(<<"cf_capture_group">>, KVS, 'undefined'));
capture_group(Call) ->
    case loaded('kapps_call') of
        'false' -> {'error', 'nil'};
        'true' -> present(kapps_call:kvs_fetch('cf_capture_group', Call))
    end.

%%%=============================================================================
%%% Commands
%%%
%%% Every one of these is a no-op without `kapps_call_command', so a callflow
%%% action's decisions can be tested without a channel to send them to.
%%%=============================================================================

-spec answer(call()) -> 'nil'.
answer(Call) ->
    command(<<"answer">>, <<>>, fun() -> kapps_call_command:answer(Call) end).

%% @doc Answer with `Insert-At: now', so the switch runs it as it arrives
%% instead of putting it on the end of the channel's command queue where the
%% next `hold' -- which carries `Insert-At: flush' -- would throw it away.
-spec answer_now(call()) -> 'nil'.
answer_now(Call) ->
    command(<<"answer">>, <<"now">>, fun() -> kapps_call_command:answer_now(Call) end).

-spec hangup(call()) -> 'nil'.
hangup(Call) ->
    command(<<"hangup">>, <<>>, fun() -> kapps_call_command:hangup(Call) end).

%% @doc End the channel's bridge, or the ring it is waiting on, and keep the
%% channel: `hangup' with `Other-Leg-Only' and `Insert-At: now', which
%% `ecallmgr_call_command' turns into `unbridge' and `ecallmgr_util' runs as
%% `uuid_park' on this channel.
-spec unbridge(call()) -> 'nil'.
unbridge(Call) ->
    command(<<"unbridge">>, <<>>, fun() -> kapps_call_command:hangup('true', Call) end).

%% @doc Hold with the media to play while held, or the default when it is
%% empty.
-spec hold(call(), binary()) -> 'nil'.
hold(Call, <<>>) ->
    command(<<"hold">>, <<>>, fun() -> kapps_call_command:hold(Call) end);
hold(Call, Media) ->
    command(<<"hold">>, Media, fun() -> kapps_call_command:hold(Media, Call) end).

%% @doc The same hold on the end of the channel's command queue, behind
%% whatever is running and whatever is already queued, instead of in place of
%% them. `kapps_call_command:hold_command/2' carries `Insert-At: flush'; this
%% is that command with `tail'.
-spec hold_queued(call(), binary()) -> 'nil'.
hold_queued(Call, Media) ->
    command(<<"hold_queued">>, Media, fun() ->
                    Command = kapps_call_command:hold_command(undefined_if_empty(Media), Call),
                    kapps_call_command:send_command(kz_json:set_value(<<"Insert-At">>, <<"tail">>, Command), Call)
            end).

%% @doc Stop the running application and clear the command queue, which is
%% the only thing that ends hold: `hold' runs until it is interrupted and
%% nothing queued behind it is ever reached.
-spec flush(call()) -> 'nil'.
flush(Call) ->
    command(<<"flush">>, <<>>, fun() -> kapps_call_command:flush(Call) end).

-spec park(call()) -> 'nil'.
park(Call) ->
    command(<<"park">>, <<>>, fun() -> kapps_call_command:park(Call) end).

-spec play(call(), binary()) -> 'nil'.
play(Call, Media) ->
    command(<<"play">>, Media, fun() -> kapps_call_command:play(Media, Call) end).

%% @doc Queue a prompt and return at once. The caller hears it only for as
%% long as the channel outlives the command, so an action that has nothing
%% to do after it wants `prompt_and_wait/2' instead.
-spec prompt(call(), binary()) -> 'nil'.
prompt(Call, Prompt) ->
    command(<<"prompt">>, Prompt, fun() -> kapps_call_command:prompt(Prompt, Call) end).

-define(PROMPT_TIMEOUT_MS, 60 * 1000).

%%------------------------------------------------------------------------------
%% @doc Play a prompt and wait for the switch to say it has finished.
%%
%% This is `kapps_call_command:b_prompt/2' written out, for the timeout.
%% `prompt/2' queues the noop and the play together and answers the noop's
%% id; `wait_for_noop/3' waits for that noop's `CHANNEL_EXECUTE_COMPLETE'.
%%
%% `b_prompt/2' would wait `max_wait_ms', a day by default, and it is not
%% always the channel's destruction that ends it: a process that has already
%% consumed the one `CHANNEL_DESTROY' `cf_exe' relays never sees another, so
%% the wait runs to the timeout and holds `cf_exe', this process and their
%% bindings open for all of it. A minute is far longer than any prompt and
%% short enough that a lost channel costs nothing.
%% @end
%%------------------------------------------------------------------------------
-spec prompt_and_wait(call(), binary()) -> {'ok', 'nil'} | {'error', binary()}.
prompt_and_wait(Call, Prompt) ->
    note(<<"prompt_and_wait">>, Prompt),
    case loaded('kapps_call_command') of
        'false' -> scripted_play();
        'true' ->
            played(catching(fun() ->
                                    NoopId = kapps_call_command:prompt(Prompt, Call),
                                    kapps_call_command:wait_for_noop(Call, NoopId, ?PROMPT_TIMEOUT_MS)
                            end))
    end.

-spec played(any()) -> {'ok', 'nil'} | {'error', binary()}.
played({'ok', _Whatever}) -> {'ok', 'nil'};
played({'error', 'channel_hungup'}) -> {'error', <<"hungup">>};
%% A timeout, an execution error the switch reported, or no channel at all.
played(_Other) -> {'error', <<"unavailable">>}.

-spec say(call(), binary(), binary(), binary(), binary()) -> 'nil'.
say(Call, Text, Type, Method, Language) ->
    command(<<"say">>, Text, fun() -> kapps_call_command:say(Text, Type, Method, Language, Call) end).

%% @doc One queued command built from a list of macro items, each of which
%% arrives as an object with a `type'. See `kazoo/call.MacroItem'.
-spec audio_macro(call(), binary()) -> 'nil'.
audio_macro(Call, Json) ->
    command(<<"audio_macro">>, Json, fun() ->
                    Prompts = [macro(Item) || Item <- decode_list(Json)],
                    kapps_call_command:audio_macro(Prompts, Call)
            end).

%% @doc The same macro with `Insert-At: interrupt': played in place of a hold,
%% and behind a bridge.
-spec audio_macro_interrupting(call(), binary()) -> 'nil'.
audio_macro_interrupting(Call, Json) ->
    command(<<"audio_macro_interrupting">>, Json, fun() ->
                    Prompts = [macro(Item) || Item <- decode_list(Json)],
                    kapps_call_command:audio_macro(Prompts, Call, kz_binary:rand_hex(3), <<"interrupt">>)
            end).

-spec macro(map()) -> tuple().
macro(#{<<"type">> := <<"play">>, <<"media">> := Media}) ->
    {'play', Media};
macro(#{<<"type">> := <<"prompt">>, <<"name">> := Name}) ->
    {'prompt', Name};
macro(#{<<"type">> := <<"say">>
       ,<<"text">> := Text
       ,<<"say_type">> := Type
       ,<<"method">> := Method
       ,<<"language">> := Language
       }) ->
    {'say', Text, Type, Method, Language};
macro(#{<<"type">> := <<"tts">>, <<"text">> := Text}) ->
    {'tts', Text};
macro(#{<<"type">> := <<"tones">>, <<"tones">> := Tones}) ->
    {'tones', [kz_json:from_map(Tone) || Tone <- Tones]}.

%% @doc Ring the endpoints. The command goes to this call's control queue, so
%% the new leg originates from this channel's media server.
-spec bridge(call(), binary(), integer(), binary(), boolean(), binary()) -> 'nil'.
bridge(Call, EndpointsJson, Timeout, Strategy, IgnoreEarlyMedia, Ringback) ->
    command(<<"bridge">>, <<>>, fun() ->
                    Endpoints = [kz_json:from_map(Endpoint)
                                 || Endpoint <- decode_list(EndpointsJson)
                                ],
                    kapps_call_command:bridge(Endpoints
                                             ,Timeout
                                             ,Strategy
                                             ,IgnoreEarlyMedia
                                             ,undefined_if_empty(Ringback)
                                             ,Call
                                             )
            end).

%% @doc Ring the endpoints in place of whatever the channel is doing:
%% `kapps_call_command:bridge_command/9' with `Insert-At: flush', and the
%% ringback the caller hears while the phones ring. Early media is ignored
%% in favour of it.
%%
%% Unlike the other commands it says whether it went out: an offer that
%% could not even send its bridge has rung nobody, and must not wait out a
%% ring timeout to be read as a miss. `kapps_call_command:send_command/2'
%% answers `ok' having published nothing when the call has no control queue,
%% and a publish with no broker to take it is dropped with a debug line, so
%% both are looked for first (`unsendable/1'). A publish the broker drops
%% after that still looks sent.
-spec bridge_interrupting(call(), binary(), integer(), binary(), binary()) ->
          {'ok', 'nil'} | {'error', binary()}.
bridge_interrupting(Call, EndpointsJson, Timeout, Strategy, Ringback) ->
    case unsendable(Call) of
        {'error', _}=Error -> Error;
        'ok' -> send_bridge_interrupting(Call, EndpointsJson, Timeout, Strategy, Ringback)
    end.

-spec send_bridge_interrupting(call(), binary(), integer(), binary(), binary()) ->
          {'ok', 'nil'} | {'error', binary()}.
send_bridge_interrupting(Call, EndpointsJson, Timeout, Strategy, Ringback) ->
    checked(<<"bridge_interrupting">>, Ringback, fun() ->
                    Endpoints = [kz_json:from_map(Endpoint)
                                 || Endpoint <- decode_list(EndpointsJson)
                                ],
                    Command = kapps_call_command:bridge_command(Endpoints
                                                               ,Timeout
                                                               ,Strategy
                                                               ,'true'
                                                               ,undefined_if_empty(Ringback)
                                                               ,'undefined'
                                                               ,<<"false">>
                                                               ,'undefined'
                                                               ,Call
                                                               ),
                    kapps_call_command:send_command([{<<"Insert-At">>, <<"flush">>} | Command], Call)
            end).

%% @doc Wait for the bridge to succeed, fail or time out. The answer is the
%% pair `kazoo/call.wait_for_bridge' reads: what happened, and the event that
%% says it.
-spec wait_for_bridge(call(), timeout()) -> {binary(), map()}.
wait_for_bridge(Call, Timeout) ->
    case loaded('kapps_call_command') of
        'false' -> {<<"timeout">>, #{}};
        'true' -> bridge_result(catching(fun() -> kapps_call_command:wait_for_bridge(Timeout, Call) end))
    end.

-spec bridge_result(any()) -> {binary(), map()}.
bridge_result({'ok', JObj}) -> {<<"bridged">>, kz_json:to_map(JObj)};
bridge_result({'fail', JObj}) -> {<<"failed">>, kz_json:to_map(JObj)};
bridge_result({'error', 'timeout'}) -> {<<"timeout">>, #{}};
bridge_result({'error', JObj}) ->
    case kz_json:is_json_object(JObj) of
        'true' -> {<<"failed">>, kz_json:to_map(JObj)};
        'false' -> {<<"timeout">>, #{}}
    end;
bridge_result(_Other) -> {<<"timeout">>, #{}}.

%% @doc Start or stop recording the call. `Media' empty leaves the name to
%% Kazoo, `TimeLimit' zero leaves the limit at its default.
-spec record_call(call(), binary(), binary(), integer()) -> 'nil'.
record_call(Call, Action, Media, TimeLimit) ->
    Options = props_filter([{<<"Media-Name">>, undefined_if_empty(Media)}
                           ,{<<"Time-Limit">>, undefined_if_zero(TimeLimit)}
                           ]),
    command(<<"record_call">>, Action, fun() -> kapps_call_command:record_call(Options, Action, Call) end).

%% @doc Start a recording that `media_mgr' stores, called `Name' plus the
%% format's extension. The command is `kapps_call_recording''s, as
%% `kapps_call:start_recording/2' sends it, except that it goes in `now':
%% `start_recording/2' queues it at the tail, where it would wait behind a
%% running bridge until the call was over.
-spec start_recording(call(), binary(), binary()) -> 'nil'.
start_recording(Call, Name, SettingsJson) ->
    command(<<"start_recording">>, Name, fun() ->
                    Settings = decode(SettingsJson),
                    Format = kapps_call_recording:get_format(kz_json:get_ne_binary_value(<<"format">>, Settings)),
                    MediaName = kapps_call_recording:get_media_name(Name, Format),
                    Data = kz_json:set_value(<<"media_name">>, MediaName, Settings),
                    Command = kapps_call_recording:record_call_command(Data, Call),
                    kapps_call_command:send_command(kz_json:set_value(<<"Insert-At">>, <<"now">>, Command), Call)
            end).

%% @doc Write channel and application variables on the channel itself, which
%% is what makes them visible to the CDR and to every other node.
-spec set_channel_vars(call(), binary(), binary()) -> 'nil'.
set_channel_vars(Call, CcvsJson, CavsJson) ->
    command(<<"set_channel_vars">>, <<>>, fun() ->
                    kapps_call_command:set(json_or_undefined(CcvsJson)
                                          ,json_or_undefined(CavsJson)
                                          ,Call
                                          )
            end).

%% @doc The next call event for this process, as a map.
-spec receive_event(timeout()) -> {'ok', map()} | {'error', 'timeout'}.
receive_event(Timeout) ->
    case loaded('kapps_call_command') of
        'false' -> {'error', 'timeout'};
        'true' ->
            case catching(fun() -> kapps_call_command:receive_event(Timeout) end) of
                {'ok', JObj} -> {'ok', kz_json:to_map(JObj)};
                _Other -> {'error', 'timeout'}
            end
    end.

%% @doc Hand an event on to another process in the shape that process's own
%% `receive_event' expects.
-spec relay_event(pid(), binary()) -> 'nil'.
relay_event(Pid, Json) ->
    command(<<"relay_event">>, <<>>, fun() -> kapps_call_command:relay_event(Pid, decode(Json)) end).

-spec wait_for_hangup(timeout()) -> {'ok', 'nil'} | {'error', 'timeout'}.
wait_for_hangup(Timeout) ->
    case loaded('kapps_call_command') of
        'false' -> {'error', 'timeout'};
        'true' ->
            case catching(fun() -> kapps_call_command:wait_for_hangup(Timeout) end) of
                {'ok', 'channel_hungup'} -> {'ok', 'nil'};
                _Other -> {'error', 'timeout'}
            end
    end.

%% @doc One DTMF digit, or why there was none: `hungup' when the channel went
%% away first, `timeout' when nothing was pressed.
-spec wait_for_dtmf(timeout()) -> {'ok', binary()} | {'error', binary()}.
wait_for_dtmf(Timeout) ->
    case loaded('kapps_call_command') of
        'false' -> {'error', <<"timeout">>};
        'true' -> dtmf_result(catching(fun() -> kapps_call_command:wait_for_dtmf(Timeout) end))
    end.

-spec dtmf_result(any()) -> {'ok', binary()} | {'error', binary()}.
dtmf_result({'ok', Digit}) when is_binary(Digit) -> {'ok', Digit};
dtmf_result({'error', 'channel_hungup'}) -> {'error', <<"hungup">>};
dtmf_result(_Other) -> {'error', <<"timeout">>}.

%% @doc Digits, up to `MaxDigits' of them, until `Timeout' milliseconds pass
%% with nothing pressed. An empty answer is nobody pressing anything, which
%% is not an error; `hungup' is the channel going away first.
-spec collect_digits(call(), non_neg_integer(), timeout()) ->
          {'ok', binary()} | {'error', binary()}.
collect_digits(Call, MaxDigits, Timeout) ->
    note(<<"collect_digits">>, <<>>),
    case loaded('kapps_call_command') of
        'false' -> scripted_digits();
        'true' ->
            digits_result(catching(fun() ->
                                           kapps_call_command:collect_digits(MaxDigits, Timeout, Call)
                                   end))
    end.

%% @doc Play a system prompt and collect what is pressed after it, retrying
%% `Tries' times and playing `InvalidPrompt' when the last try is still
%% wrong. This is the whole of an id-and-PIN exchange, and it is one command
%% so the switch runs it without a round trip per digit.
%%
%% An empty `InvalidPrompt' means say nothing on the last failure.
-spec prompt_and_collect_digits(call(), binary(), non_neg_integer(), non_neg_integer(), timeout(), binary()) ->
          {'ok', binary()} | {'error', binary()}.
prompt_and_collect_digits(Call, Prompt, MaxDigits, Tries, Timeout, InvalidPrompt) ->
    note(<<"prompt_and_collect_digits">>, Prompt),
    case loaded('kapps_call_command') of
        'false' -> scripted_digits();
        'true' ->
            digits_result(
              catching(fun() ->
                               kapps_call_command:b_prompt_and_collect_digits(1
                                                                             ,MaxDigits
                                                                             ,Prompt
                                                                             ,Tries
                                                                             ,Timeout
                                                                             ,invalid_prompt(InvalidPrompt)
                                                                             ,Call
                                                                             )
                       end)
             )
    end.

-spec invalid_prompt(binary()) -> binary() | 'undefined'.
invalid_prompt(<<>>) -> 'undefined';
invalid_prompt(Prompt) -> Prompt.

-spec digits_result(any()) -> {'ok', binary()} | {'error', binary()}.
digits_result({'ok', Digits}) when is_binary(Digits) -> {'ok', Digits};
digits_result({'error', 'channel_hungup'}) -> {'error', <<"hungup">>};
digits_result(Digits) when is_binary(Digits) -> {'ok', Digits};
digits_result(_Other) -> {'error', <<"unavailable">>}.

%%%=============================================================================
%%% Media
%%%=============================================================================

%% @doc A media name as a path the switch can play, resolved against the
%% account.
-spec media_path(binary(), binary()) -> binary().
media_path(Media, AccountId) ->
    case loaded('kz_media_util') of
        'false' -> Media;
        'true' ->
            try kz_media_util:media_path(Media, AccountId) of
                'undefined' -> Media;
                Path when is_binary(Path) -> Path;
                _Other -> Media
            catch
                _E:_R -> Media
            end
    end.

%% @doc The media a system prompt resolves to for this call's language.
-spec prompt_path(call(), binary(), binary()) -> {'ok', binary()} | {'error', 'nil'}.
prompt_path(Call, Prompt, Language) ->
    case loaded('kapps_call') of
        'false' -> {'error', 'nil'};
        'true' ->
            try kapps_call:get_prompt(Call, Prompt, undefined_if_empty(Language)) of
                Path -> present(Path)
            catch
                _E:_R -> {'error', 'nil'}
            end
    end.

%%------------------------------------------------------------------------------
%% @doc Ask the switch to run its dialplan for the channel again.
%%
%% There is no `kapps_call_command' function for this one, so the command is
%% built here as `kapi_dialplan:execute_extension/1' validates it:
%% application name, the channel, the extension, and `Reset' so the channel's
%% application counters start again. `Insert-At' is `now' because a re-run
%% that queued behind the hold music would never happen.
%% @end
%%------------------------------------------------------------------------------
-spec execute_extension(kapps_call:call(), binary()) -> 'nil'.
execute_extension(Call, Extension) ->
    command(<<"execute_extension">>, Extension, fun() ->
                    kapps_call_command:send_command(
                      [{<<"Application-Name">>, <<"execute_extension">>}
                      ,{<<"Extension">>, Extension}
                      ,{<<"Reset">>, 'true'}
                      ,{<<"Insert-At">>, <<"now">>}
                      ,{<<"Call-ID">>, kapps_call:call_id(Call)}
                      ]
                                                  ,Call
                     )
            end).

%%%=============================================================================
%%% Internal
%%%=============================================================================

-spec command(binary(), binary(), fun(() -> any())) -> 'nil'.
command(Name, Argument, Fun) ->
    note(Name, Argument),
    _ = case loaded('kapps_call_command') of
            'false' -> 'ok';
            'true' -> catching(Fun)
        end,
    'nil'.

%% @doc The same, answering whether the command went out. A publish that
%% threw -- a command that did not validate, a broker that would not take it
%% -- is an error; anything else is taken as sent, which is all a command
%% can say.
-spec checked(binary(), binary(), fun(() -> any())) -> {'ok', 'nil'} | {'error', binary()}.
checked(Name, Argument, Fun) ->
    note(Name, Argument),
    case loaded('kapps_call_command') of
        'false' -> {'ok', 'nil'};
        'true' -> sent(catching(Fun))
    end.

%% @doc What can be seen before a command is sent that would have it go
%% nowhere. Nothing here asks anybody anything or waits.
%%
%% A call with a custom publisher sends through it and needs neither. One
%% without has its command published to its control queue, and
%% `send_command/2' publishes nothing when there is none. Then the broker:
%% `kz_amqp_connections:is_available/0' reads the connections table, and a
%% node with no broker connection up would hand the command to a channel
%% that is not there. The channel itself is not looked at: finding it
%% without asking for one sees only channels this process already holds,
%% and asking waits. Anything that cannot be read is no reason not to try.
-spec unsendable(call()) -> 'ok' | {'error', binary()}.
unsendable(?FAKE(Map)) ->
    control_queue_in(maps:get(<<"Control-Queue">>, Map, 'undefined'));
unsendable(Call) ->
    case loaded('kapps_call') of
        'false' -> 'ok';
        'true' ->
            try is_function(kapps_call:custom_publish_function(Call), 2) of
                'true' -> 'ok';
                'false' ->
                    case control_queue_in(kapps_call:control_queue(Call)) of
                        'ok' -> broker_available();
                        Error -> Error
                    end
            catch
                _E:_R -> 'ok'
            end
    end.

-spec control_queue_in(any()) -> 'ok' | {'error', binary()}.
control_queue_in(<<_, _/binary>>) -> 'ok';
control_queue_in(_None) -> {'error', <<"the call has no control queue">>}.

-spec broker_available() -> 'ok' | {'error', binary()}.
broker_available() ->
    case loaded('kz_amqp_connections') of
        'false' -> 'ok';
        'true' ->
            try kz_amqp_connections:is_available() of
                'false' -> {'error', <<"no broker connection is available">>};
                _Available -> 'ok'
            catch
                _E:_R -> 'ok'
            end
    end.

-spec sent(any()) -> {'ok', 'nil'} | {'error', binary()}.
sent({'error', Reason}) when is_binary(Reason) -> {'error', Reason};
sent({'error', Reason}) when is_atom(Reason) -> {'error', atom_to_binary(Reason, 'utf8')};
sent({'error', Reason}) -> {'error', iolist_to_binary(io_lib:format("~p", [Reason]))};
sent(_Sent) -> {'ok', 'nil'}.

-spec catching(fun(() -> any())) -> any().
catching(Fun) ->
    try Fun()
    catch
        _E:_R -> {'error', 'unavailable'}
    end.

-spec loaded(atom()) -> boolean().
loaded(Module) ->
    case code:ensure_loaded(Module) of
        {'module', Module} -> 'true';
        {'error', _Reason} -> 'false'
    end.

-spec decode(binary()) -> any().
decode(Json) ->
    case loaded('kz_json') of
        'false' -> json:decode(Json);
        'true' -> kz_json:from_map(decode_map(Json))
    end.

%% @doc The same, for a value that is not necessarily an object: what the
%% key-value store holds is whatever the caller put there, and a number that
%% went in has to come back a number.
-spec decode_value(binary()) -> any().
decode_value(Json) -> term(json:decode(Json)).

-spec term(any()) -> any().
term(Map) when is_map(Map) ->
    case loaded('kz_json') of
        'false' -> Map;
        'true' -> kz_json:from_map(Map)
    end;
term(List) when is_list(List) -> [term(Item) || Item <- List];
term(Other) -> Other.

-spec decode_map(binary()) -> map().
decode_map(Json) ->
    case json:decode(Json) of
        Map when is_map(Map) -> Map;
        Other -> #{<<"value">> => Other}
    end.

-spec decode_list(binary()) -> [map()].
decode_list(Json) ->
    case json:decode(Json) of
        List when is_list(List) -> [Item || Item <- List, is_map(Item)];
        _Other -> []
    end.

-spec to_map_value(any()) -> any().
to_map_value(Value) ->
    case loaded('kz_json')
        andalso kz_json:is_json_object(Value)
    of
        'true' -> kz_json:to_map(Value);
        'false' -> Value
    end.

-spec json_or_undefined(binary()) -> any().
json_or_undefined(<<"{}">>) -> 'undefined';
json_or_undefined(Json) -> decode(Json).

-spec undefined_if_empty(binary()) -> 'undefined' | binary().
undefined_if_empty(<<>>) -> 'undefined';
undefined_if_empty(Value) -> Value.

-spec undefined_if_zero(integer()) -> 'undefined' | integer().
undefined_if_zero(0) -> 'undefined';
undefined_if_zero(Value) -> Value.

-spec props_filter([{binary(), any()}]) -> [{binary(), any()}].
props_filter(Props) -> [KV || {_, V}=KV <- Props, V =/= 'undefined'].

%%%=============================================================================
%%% Test support
%%%
%%% Without `kapps_call_command' a command is a no-op, which makes a callflow
%%% action runnable under `gleam test' but says nothing about what it would
%%% have sent. These turn the no-op into a record: while a process is
%%% recording, every command it sends is kept in the order it sent them, and
%%% the ones that wait on the caller answer what the test scripted.
%%%
%%% One key holds all three, so `record/0' is the whole reset and a script
%%% cannot outlive the test that wrote it: nothing is read from a process
%%% that is not recording, and starting to record forgets what came before.
%%%
%%% It is all per-process, so one test cannot see another's channel and
%%% nothing has to be started or torn down. On a node nothing is ever
%%% recording, so `note/2' is one dictionary read.
%%%
%%% The Gleam side is `kazoo/testing/channel'.
%%%=============================================================================

-define(CHANNEL, 'kazoo_gleam_channel').

-type scripted() :: {'ok', binary()} | {'error', binary()}.
-type channel() :: {[{binary(), binary()}], [scripted()], [scripted()]}.

%% @doc Start recording in this process, forgetting anything recorded before
%% and any answer still scripted.
-spec record() -> 'nil'.
record() ->
    _ = put(?CHANNEL, {[], [], []}),
    'nil'.

%% @doc What has been sent since, oldest first.
-spec sent() -> [{binary(), binary()}].
sent() ->
    case get(?CHANNEL) of
        {Sent, _Digits, _Plays} -> lists:reverse(Sent);
        _NotRecording -> []
    end.

%% @doc Answer this process's next digit collections with these, in order. A
%% collection past the end of the list gets nothing typed, as one without a
%% channel always has.
-spec collect_answers([scripted()]) -> 'nil'.
collect_answers(Digits) ->
    {Sent, _Digits, Plays} = channel(),
    _ = put(?CHANNEL, {Sent, Digits, Plays}),
    'nil'.

%% @doc The same for the prompts this process waits on.
-spec play_results([scripted()]) -> 'nil'.
play_results(Plays) ->
    {Sent, Digits, _Plays} = channel(),
    _ = put(?CHANNEL, {Sent, Digits, Plays}),
    'nil'.

%% @doc Keep one command, if anybody is listening.
-spec note(binary(), binary()) -> 'ok'.
note(Name, Argument) ->
    case get(?CHANNEL) of
        {Sent, Digits, Plays} ->
            _ = put(?CHANNEL, {[{Name, Argument} | Sent], Digits, Plays}),
            'ok';
        _NotRecording -> 'ok'
    end.

%% @doc The next scripted digits, or the unavailable a collection without a
%% channel has always answered.
-spec scripted_digits() -> scripted().
scripted_digits() ->
    case get(?CHANNEL) of
        {Sent, [Answer | Rest], Plays} ->
            _ = put(?CHANNEL, {Sent, Rest, Plays}),
            Answer;
        _Nothing -> {'error', <<"unavailable">>}
    end.

%% @doc The next scripted play, or the unavailable a prompt with no channel
%% to play it on answers.
-spec scripted_play() -> {'ok', 'nil'} | {'error', binary()}.
scripted_play() ->
    case get(?CHANNEL) of
        {Sent, Digits, [Result | Rest]} ->
            _ = put(?CHANNEL, {Sent, Digits, Rest}),
            as_play(Result);
        _Nothing -> {'error', <<"unavailable">>}
    end.

%% @doc A scripted result in the shape `prompt_and_wait' answers in. It is
%% already the Gleam `Result', so only the `ok' payload has to change: there
%% is nothing to hand back from a prompt but the fact that it played.
-spec as_play(scripted()) -> {'ok', 'nil'} | {'error', binary()}.
as_play({'ok', _Nothing}) -> {'ok', 'nil'};
as_play({'error', Reason}) -> {'error', Reason}.

-spec channel() -> channel().
channel() ->
    case get(?CHANNEL) of
        {_Sent, _Digits, _Plays}=Channel -> Channel;
        _NotRecording -> {[], [], []}
    end.
