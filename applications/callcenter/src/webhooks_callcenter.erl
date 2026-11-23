%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2026, Vonix LLC
%%% @doc Call center events as HTTP hooks.
%%%
%%% This Source Code Form is subject to the terms of the Mozilla Public
%%% License, v. 2.0. If a copy of the MPL was not distributed with this
%%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%%
%%% One hook type per event on the `callcenter' topic exchange, so an
%%% integrator subscribes to agent answers without also taking every position
%%% change. The hook names are the event names with the application in front:
%%% `callcenter_agent_answered', `callcenter_queue_stats' and so on.
%%%
%%% The listener binds every account -- webhooks has one shared listener and
%%% decides per event whether anybody asked for it -- and the account comes
%%% out of the event's own `Account-ID', which every event on this API
%%% carries.
%%%
%%% The responder is bound to `{callcenter, *}' rather than to each name.
%%% That is deliberate: an event whose name this module does not know is
%%% logged and dropped, which is what should happen while the two halves of
%%% the API are landing in different branches, instead of an unroutable
%%% event killing the shared listener's responder.
%%%
%%% Validation goes through `kapi_callcenter's own definitions, found by
%%% name, so this module does not restate any event's required fields. An
%%% event with a hook here and no definition yet is fired unvalidated and
%%% starts being validated the moment the definition lands.
%%%
%%% No `-include' and no `lager' macro: this lives in a gleam package's
%%% `src'. See the top of `kapi_callcenter'.
%%% @end
%%%-----------------------------------------------------------------------------
-module(webhooks_callcenter).

-behaviour(gen_webhook).

-export([init/0
        ,bindings_and_responders/0
        ,handle/2
        ]).

-export([hook_name/1, hook_id/1, events/0]).

%% `{EventName, Name, Description}'. The name and description are what an
%% integrator reads in the list of available hooks, so they say what arriving
%% at the hook's URL means rather than what the AMQP message is.
-define(EVENTS
       ,[{<<"member_connected">>
         ,<<"Queue Member Connected">>
         ,<<"This webhook is triggered when a caller waiting in a queue is connected to an agent">>
         }
        ,{<<"member_position">>
         ,<<"Queue Member Position">>
         ,<<"This webhook is triggered when a caller's position in a queue changes">>
         }
        ,{<<"member_result">>
         ,<<"Queue Member Result">>
         ,<<"This webhook is triggered when a queue call ends, with how it ended">>
         }
        ,{<<"agent_availability">>
         ,<<"Agent Availability">>
         ,<<"This webhook is triggered when an agent logs in or out, goes on break or comes back">>
         }
        ,{<<"agent_activity">>
         ,<<"Agent Activity">>
         ,<<"This webhook is triggered when an agent's phones start or stop ringing, answer or hang up">>
         }
        ,{<<"agent_offer">>
         ,<<"Agent Offer">>
         ,<<"This webhook is triggered when a waiting caller is offered to an agent">>
         }
        ,{<<"agent_answered">>
         ,<<"Agent Answered">>
         ,<<"This webhook is triggered when an agent answers a queue call">>
         }
        ,{<<"agent_wrapup">>
         ,<<"Agent Wrapup">>
         ,<<"This webhook is triggered when an agent's queue call ends and their wrap-up starts">>
         }
        ,{<<"queue_stats">>
         ,<<"Queue Stats">>
         ,<<"This webhook is triggered when a queue's waiting count or longest wait changes">>
         }
        ]
       ).

-define(CATEGORY, <<"callcenter">>).

%% The AMQP plumbing, which says nothing to the receiver of a hook.
-define(REMOVE_KEYS, [<<"App-Name">>
                     ,<<"App-Version">>
                     ,<<"Event-Category">>
                     ,<<"Event-Name">>
                     ,<<"Msg-ID">>
                     ,<<"Node">>
                     ,<<"Server-ID">>
                     ]).

%%------------------------------------------------------------------------------
%% @doc Put one metadata document per event in the master account, which is
%% what makes the hook selectable.
%% @end
%%------------------------------------------------------------------------------
-spec init() -> 'ok'.
init() -> lists:foreach(fun init_event/1, ?EVENTS).

-spec init_event({kz_term:ne_binary(), kz_term:ne_binary(), kz_term:ne_binary()}) -> 'ok'.
init_event({EventName, Name, Description}) ->
    Id = hook_id(EventName),
    Metadata = kz_json:from_list([{<<"_id">>, Id}
                                 ,{<<"name">>, Name}
                                 ,{<<"description">>, Description}
                                 ]),
    webhooks_util:init_metadata(Id, Metadata).

%%------------------------------------------------------------------------------
%% @doc Every event family that carries an event, which is all of them but
%% the status query.
%% @end
%%------------------------------------------------------------------------------
-spec bindings_and_responders() -> {gen_listener:bindings()
                                   ,listener_utils:responder_start_params()
                                   }.
bindings_and_responders() ->
    {[{'callcenter', [{'restrict_to', ['call', 'agent', 'queue']}]}]
    ,[{{?MODULE, 'handle'}
      ,[{?CATEGORY, <<"*">>}]
      }
     ]
    }.

%%------------------------------------------------------------------------------
%% @doc Fire whatever hooks the event's account has for it.
%% @end
%%------------------------------------------------------------------------------
-spec handle(kz_json:object(), kz_term:proplist()) -> 'ok'.
handle(JObj, _Props) ->
    handle_event(kz_api:event_name(JObj), JObj).

-spec handle_event(kz_term:api_ne_binary(), kz_json:object()) -> 'ok'.
handle_event(EventName, JObj) ->
    case lists:keymember(EventName, 1, ?EVENTS) of
        'false' ->
            lager:log('debug', self(), "no hook for call center event ~p", [EventName]);
        'true' ->
            'true' = validate(EventName, JObj),
            maybe_send_event(EventName
                            ,kz_json:get_ne_binary_value(<<"Account-ID">>, JObj)
                            ,JObj
                            )
    end.

-spec maybe_send_event(kz_term:ne_binary(), kz_term:api_ne_binary(), kz_json:object()) -> 'ok'.
maybe_send_event(EventName, 'undefined', _JObj) ->
    lager:log('warning', self(), "call center ~s event has no account", [EventName]);
maybe_send_event(EventName, AccountId, JObj) ->
    HookName = hook_name(EventName),
    case webhooks_util:find_webhooks(HookName, AccountId) of
        [] -> lager:log('debug', self(), "no hooks for ~s in ~s", [HookName, AccountId]);
        Hooks ->
            webhooks_util:fire_hooks(format(HookName, JObj)
                                    ,format_v2_event(HookName, JObj)
                                    ,Hooks
                                    )
    end.

%%------------------------------------------------------------------------------
%% @doc The hook an account subscribes to for one event.
%% @end
%%------------------------------------------------------------------------------
-spec hook_name(kz_term:ne_binary()) -> kz_term:ne_binary().
hook_name(EventName) -> <<"callcenter_", EventName/binary>>.

%%------------------------------------------------------------------------------
%% @doc The id of that hook's metadata document. `webhooks' takes the hook
%% name from this by dropping the prefix, so the two have to agree.
%% @end
%%------------------------------------------------------------------------------
-spec hook_id(kz_term:ne_binary()) -> kz_term:ne_binary().
hook_id(EventName) ->
    HookName = hook_name(EventName),
    <<"webhooks_", HookName/binary>>.

%%------------------------------------------------------------------------------
%% @doc Every event with a hook, in the order they are registered.
%% @end
%%------------------------------------------------------------------------------
-spec events() -> kz_term:ne_binaries().
events() -> [EventName || {EventName, _Name, _Description} <- ?EVENTS].

%%%=============================================================================
%%% Internal functions
%%%=============================================================================

%%------------------------------------------------------------------------------
%% @doc `kapi_callcenter's own validator for this event, if it has one yet.
%% @end
%%------------------------------------------------------------------------------
-spec validate(kz_term:ne_binary(), kz_json:object()) -> boolean().
validate(EventName, JObj) ->
    case definition(EventName) of
        'undefined' ->
            lager:log('info', self(), "no api definition for ~s yet, firing unvalidated", [EventName]),
            'true';
        Definition -> (kapi_definition:validate_fun(Definition))(JObj)
    end.

-spec definition(kz_term:ne_binary()) -> kapi_definition:api() | 'undefined'.
definition(EventName) ->
    Named = fun(Definition) -> kapi_definition:name(Definition) =:= EventName end,
    case lists:search(Named, kapi_callcenter:api_definitions()) of
        {'value', Definition} -> Definition;
        'false' -> 'undefined'
    end.

%%------------------------------------------------------------------------------
%% @doc The v1 payload: the event's fields with the AMQP plumbing dropped and
%% the names lower-cased, which is the same shape the WebSocket relay emits.
%% @end
%%------------------------------------------------------------------------------
-spec format(kz_term:ne_binary(), kz_json:object()) -> kz_json:object().
format(HookName, JObj) ->
    kz_json:set_value(<<"hook_event">>
                     ,HookName
                     ,kz_json:normalize_jobj(JObj, ?REMOVE_KEYS, [])
                     ).

-spec format_v2_event(kz_term:ne_binary(), kz_json:object()) -> kz_json:object().
format_v2_event(HookName, JObj) ->
    kz_json:from_list([{<<"action">>, <<"event">>}
                      ,{<<"name">>, HookName}
                      ,{<<"data">>, webhooks_util:sanitize_event(JObj)}
                      ]).
