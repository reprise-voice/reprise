%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2026, Vonix LLC
%%% @doc The call center's AMQP API.
%%%
%%% This Source Code Form is subject to the terms of the Mozilla Public
%%% License, v. 2.0. If a copy of the MPL was not distributed with this
%%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%%
%%% Two shapes of message, and the difference matters.
%%%
%%% The first is work: a caller waiting in a queue. Accounts hash into a
%%% fixed number of shards -- `callcenter/shards' in the application, from
%%% `system_config/callcenter', 64 by default -- and each shard has one
%%% durable classic queue,
%%% `callcenter.member.&lt;shard&gt;'. It is consumed directly and its
%%% messages are published to the default exchange with the queue name as the
%%% routing key, so there is no exchange, no binding and nothing to discover:
%%% the queue name is a function of the account id. It holds one message per
%%% waiting caller, unacked until the caller is connected or gone, and the
%%% node consuming it -- exclusively, which is what makes it that node's
%%% shard -- dispatches every account in the shard; the loss of that node
%%% redelivers every waiting caller to whichever node consumes next.
%%%
%%% A member message carries the caller's whole `kapps_call' JSON rather than
%%% an id, because the node that rebuilds it after a failover has nothing else
%%% to rebuild it from: the control queue and `Resource-Type' are both in
%%% there, and `kz_endpoint:build/3' needs the latter to make the agent's
%%% endpoints.
%%%
%%% The second shape is observation: everything else. Those go to the
%%% `callcenter' topic exchange with the account id in the routing key, so
%%% blackhole can authorise a subscription per account and webhooks and the
%%% wallboard can take the same feed:
%%%
%%% <ul>
%%% <li>`callcenter.call.&lt;account&gt;.&lt;call&gt;' -- the dispatcher's progress
%%% on one caller, for whoever watches it.</li>
%%% <li>`callcenter.agent.&lt;account&gt;.&lt;agent&gt;' -- availability, activity,
%%% offers, answers and wrap-ups.</li>
%%% <li>`callcenter.queue.&lt;account&gt;.&lt;queue&gt;' -- how many are waiting and
%%% how long the longest has been.</li>
%%% <li>`callcenter.status.&lt;account&gt;' -- a live status query.</li>
%%% <li>`callcenter.pickup.&lt;account&gt;' -- a supervisor's pickup of a
%%% waiting caller, for the node dispatching the account.</li>
%%% </ul>
%%%
%%% Each id is one word of the key, escaped by `segment/1' the way
%%% `kz_amqp_util:encode/1' escapes a call id: a SIP Call-ID has dots and an
%%% `@' in it, and unescaped it is several words that no binding of the
%%% family matches.
%%%
%%% The callflow action that put the caller in the queue does not bind that
%%% key: it hears nothing from the queue until the caller is handed back.
%%% `member_continue' goes to it straight, at the `Controller-Queue' the
%%% caller's call carries (`publish_member_continue/2'): the queue the route
%%% win came in on, where `cf_exe' already hands whatever arrives for the
%%% call to the running action, so a waiting caller costs the broker no
%%% queue, binding or consumer of its own. Its answer, `member_continuing',
%%% goes to the caller's actor the same way (`publish_member_continuing/2').
%%%
%%% A status answer does not go back on that key. It is published to the
%%% requester's own queue, because the requester collects with
%%% `kz_amqp_worker:call_collect/4' and every node that does not hold the
%%% account's shard answers "not here": broadcasting those to the account's
%%% status key would hand every other listener a pile of answers to a question
%%% it did not ask.
%%%
%%% This module has no `-include_lib', deliberately. It is compiled by gleam
%%% along with the rest of the application, which gives an `.erl' file in a
%%% package's `src' no include path to any other OTP application, so the
%%% literals it would take from `kz_api.hrl' and `kz_amqp_util.hrl' are
%%% written out here instead. For the same reason there is no `lager' call in
%%% it: `lager:info/1' and friends only exist after the parse transform.
%%% @end
%%%-----------------------------------------------------------------------------
-module(kapi_callcenter).

-export([api_definitions/0, api_definition/1]).

-export([member_call/1, member_call_v/1
        ,member_cancel/1, member_cancel_v/1
        ,member_offer/1, member_offer_v/1
        ,member_connected/1, member_connected_v/1
        ,member_result/1, member_result_v/1
        ,member_position/1, member_position_v/1
        ,member_continue/1, member_continue_v/1
        ,member_continuing/1, member_continuing_v/1
        ,agent_availability/1, agent_availability_v/1
        ,agent_activity/1, agent_activity_v/1
        ,agent_offer/1, agent_offer_v/1
        ,agent_answered/1, agent_answered_v/1
        ,agent_wrapup/1, agent_wrapup_v/1
        ,queue_stats/1, queue_stats_v/1
        ,status_req/1, status_req_v/1
        ,status_resp/1, status_resp_v/1
        ,pickup_req/1, pickup_req_v/1
        ,pickup_resp/1, pickup_resp_v/1
        ]).

-export([publish_member_call/2, publish_member_call/3
        ,prepare_member_call/2
        ,publish_member_cancel/2, publish_member_cancel/3
        ,publish_member_offer/1, publish_member_offer/2
        ,publish_member_connected/1, publish_member_connected/2
        ,publish_member_result/1, publish_member_result/2
        ,publish_member_position/1, publish_member_position/2
        ,publish_member_continue/2, publish_member_continue/3
        ,publish_member_continuing/2, publish_member_continuing/3
        ,publish_agent_availability/1, publish_agent_availability/2
        ,publish_agent_activity/1, publish_agent_activity/2
        ,publish_agent_offer/1, publish_agent_offer/2
        ,publish_agent_answered/1, publish_agent_answered/2
        ,publish_agent_wrapup/1, publish_agent_wrapup/2
        ,publish_queue_stats/1, publish_queue_stats/2
        ,publish_status_req/1, publish_status_req/2
        ,publish_status_resp/2, publish_status_resp/3
        ,publish_pickup_req/1, publish_pickup_req/2
        ,publish_pickup_resp/2, publish_pickup_resp/3
        ]).

-export([bind_q/2, unbind_q/2
        ,declare_exchanges/0
        ]).

-export([exchange/0, exchange_type/0
        ,member_queue/1
        ,routing_key/3, event_routing_keys/2
        ,call_routing_key/2, agent_routing_key/2
        ,queue_routing_key/2, status_routing_key/1, pickup_routing_key/1
        ,segment/1, binding_keys/1
        ]).

-export([account_id/1, queue_id/1, agent_id/1, call_id/1]).

-define(EXCHANGE, <<"callcenter">>).
-define(EXCHANGE_TYPE, <<"topic">>).

-define(CATEGORY, <<"callcenter">>).

-define(CONTENT_TYPE, <<"application/json">>).

%% The default exchange. Publishing to it with a queue's name as the routing
%% key delivers straight to that queue, which is how the member
%% queues are fed: they are work queues, not subscriptions.
-define(DEFAULT_EXCHANGE, <<>>).

%% Every message on this API says which account it is about, and the two that
%% are not about one caller or one agent still do.
-define(KEY_ACCOUNT_ID, <<"Account-ID">>).
-define(KEY_QUEUE_ID, <<"Queue-ID">>).
-define(KEY_AGENT_ID, <<"Agent-ID">>).
-define(KEY_CALL_ID, <<"Call-ID">>).

-define(AVAILABILITIES, [<<"logged_out">>
                        ,<<"available">>
                        ,<<"available_on_demand">>
                        ,<<"on_break">>
                        ]).

-define(AVAILABILITY_SOURCES, [<<"phone">>
                              ,<<"ui">>
                              ,<<"supervisor">>
                              ,<<"no_answer">>
                              ,<<"dnd">>
                              ,<<"system">>
                              ]).

-define(ACTIVITIES, [<<"idle">>
                    ,<<"ringing">>
                    ,<<"on_call">>
                    ,<<"wrapping_up">>
                    ]).

-define(CANCEL_REASONS, [<<"hangup">>
                        ,<<"timeout">>
                        ,<<"no_agent_timeout">>
                        ,<<"exit_key">>
                        ,<<"queue_full">>
                        ,<<"transfer">>
                        ,<<"queue_deleted">>
                        ,<<"quarantined">>
                        ]).

-define(RESULTS, [<<"completed">>
                 ,<<"agent_hangup">>
                 ,<<"caller_hangup">>
                 ,<<"failed">>
                 ,<<"transferred">>
                 ,<<"queue_deleted">>
                 ]).

%% What the node dispatching an account did about a supervisor's pickup.
-define(PICKUP_RESULTS, [<<"ringing">>
                        ,<<"not_waiting">>
                        ,<<"being_offered">>
                        ,<<"supervisor_busy">>
                        ,<<"not_started">>
                        ,<<"too_late">>
                        ]).

%%%=============================================================================
%%% Definitions
%%%=============================================================================

%%------------------------------------------------------------------------------
%% @doc Every API definition in this module.
%% @end
%%------------------------------------------------------------------------------
-spec api_definitions() -> kapi_definition:apis().
api_definitions() ->
    [member_call_definition()
    ,member_cancel_definition()
    ,member_offer_definition()
    ,member_connected_definition()
    ,member_result_definition()
    ,member_position_definition()
    ,member_continue_definition()
    ,member_continuing_definition()
    ,agent_availability_definition()
    ,agent_activity_definition()
    ,agent_offer_definition()
    ,agent_answered_definition()
    ,agent_wrapup_definition()
    ,queue_stats_definition()
    ,status_req_definition()
    ,status_resp_definition()
    ,pickup_req_definition()
    ,pickup_resp_definition()
    ].

%%------------------------------------------------------------------------------
%% @doc The definition of one event, by name.
%% @see api_definitions/0
%% @end
%%------------------------------------------------------------------------------
-spec api_definition(kz_term:text()) -> kapi_definition:api().
api_definition(Name) when not is_binary(Name) ->
    api_definition(kz_term:to_binary(Name));
api_definition(<<"member_call">>) -> member_call_definition();
api_definition(<<"member_cancel">>) -> member_cancel_definition();
api_definition(<<"member_offer">>) -> member_offer_definition();
api_definition(<<"member_connected">>) -> member_connected_definition();
api_definition(<<"member_result">>) -> member_result_definition();
api_definition(<<"member_position">>) -> member_position_definition();
api_definition(<<"member_continue">>) -> member_continue_definition();
api_definition(<<"member_continuing">>) -> member_continuing_definition();
api_definition(<<"agent_availability">>) -> agent_availability_definition();
api_definition(<<"agent_activity">>) -> agent_activity_definition();
api_definition(<<"agent_offer">>) -> agent_offer_definition();
api_definition(<<"agent_answered">>) -> agent_answered_definition();
api_definition(<<"agent_wrapup">>) -> agent_wrapup_definition();
api_definition(<<"queue_stats">>) -> queue_stats_definition();
api_definition(<<"status_req">>) -> status_req_definition();
api_definition(<<"status_resp">>) -> status_resp_definition();
api_definition(<<"pickup_req">>) -> pickup_req_definition();
api_definition(<<"pickup_resp">>) -> pickup_resp_definition().

%%------------------------------------------------------------------------------
%% @doc A caller has entered a queue.
%%
%% `Call' is the whole `kapps_call:to_json/1' object: the control queue and
%% `Resource-Type' come with it, and a dispatcher that picked this message up
%% on redelivery has no other way back to them. `Callflow-Node' is the node
%% running the caller's callflow, so that a dispatcher can tell when the
%% branch the caller would have taken on timeout has died with it.
%%
%% `Handoff-ID' names this passage of the caller through the queue: the
%% callflow action waits for a `member_continue' carrying it, and nothing
%% else. `Branches' is the flows the callflow could go on into when the
%% caller leaves -- `_', `exit_key', `timeout', `no_agents',
%% `no_agent_timeout' -- which is what the caller is resumed at on another
%% callflow node when the action's own node has gone.
%% @end
%%------------------------------------------------------------------------------
-spec member_call_definition() -> kapi_definition:api().
member_call_definition() ->
    EventName = <<"member_call">>,
    Setters = [{fun kapi_definition:set_name/2, EventName}
              ,{fun kapi_definition:set_friendly_name/2, <<"Queue Member Call">>}
              ,{fun kapi_definition:set_description/2
               ,<<"A caller has joined a queue and is waiting for an agent">>
               }
              ,{fun kapi_definition:set_category/2, ?CATEGORY}
              ,{fun kapi_definition:set_build_fun/2, fun member_call/1}
              ,{fun kapi_definition:set_validate_fun/2, fun member_call_v/1}
              ,{fun kapi_definition:set_publish_fun/2, fun publish_member_call/2}
              ,{fun kapi_definition:set_required_headers/2, [?KEY_ACCOUNT_ID
                                                            ,?KEY_QUEUE_ID
                                                            ,<<"Call">>
                                                            ,<<"Callflow-Node">>
                                                            ,<<"Joined-Timestamp">>
                                                            ]}
              ,{fun kapi_definition:set_optional_headers/2, [<<"Branches">>
                                                            ,<<"Caller-ID-Name">>
                                                            ,<<"Caller-ID-Number">>
                                                            ,<<"Handoff-ID">>
                                                            ,<<"Priority">>
                                                            ,<<"Shard-Count">>
                                                            ]}
              ,{fun kapi_definition:set_values/2
               ,kapi_definition:event_type_headers(?CATEGORY, EventName)
               }
              ,{fun kapi_definition:set_types/2, [{?KEY_ACCOUNT_ID, fun is_binary/1}
                                                 ,{?KEY_QUEUE_ID, fun is_binary/1}
                                                 ,{<<"Call">>, fun kz_json:is_json_object/1}
                                                 ,{<<"Branches">>, fun kz_json:is_json_object/1}
                                                 ,{<<"Handoff-ID">>, fun is_binary/1}
                                                 ,{<<"Caller-ID-Name">>, fun is_binary/1}
                                                 ,{<<"Caller-ID-Number">>, fun is_binary/1}
                                                 ,{<<"Callflow-Node">>, fun is_binary/1}
                                                 ,{<<"Joined-Timestamp">>, fun is_integer/1}
                                                 ,{<<"Priority">>, fun is_integer/1}
                                                 ,{<<"Shard-Count">>, fun is_integer/1}
                                                 ]}
              ],
    kapi_definition:setters(Setters).

%%------------------------------------------------------------------------------
%% @doc A caller has left a queue without being connected.
%%
%% Published by whoever noticed -- the callflow action on a hangup, an exit
%% key or a timer, the dispatcher's own reconciliation -- and it is what tells
%% the dispatcher it may ack the member message.
%%
%% `Joined-Timestamp' is the Gregorian second the caller joined, as their
%% `member_call' carries it, and `Cancelled-Timestamp' the second they left. A
%% cancel can reach the shard before the `member_call' it cancels, and the
%% shard remembers it for a while: the `member_call' of that queue that
%% joined at that second is the one it cancelled, or, from a sender that did
%% not say when the caller joined, the first that joined at or before the
%% second they left. Both optional, because a node of an older release does
%% not send them.
%% @end
%%------------------------------------------------------------------------------
-spec member_cancel_definition() -> kapi_definition:api().
member_cancel_definition() ->
    EventName = <<"member_cancel">>,
    Setters = [{fun kapi_definition:set_name/2, EventName}
              ,{fun kapi_definition:set_friendly_name/2, <<"Queue Member Cancel">>}
              ,{fun kapi_definition:set_description/2
               ,<<"A caller has left a queue before being connected to an agent">>
               }
              ,{fun kapi_definition:set_category/2, ?CATEGORY}
              ,{fun kapi_definition:set_build_fun/2, fun member_cancel/1}
              ,{fun kapi_definition:set_validate_fun/2, fun member_cancel_v/1}
              ,{fun kapi_definition:set_publish_fun/2, fun publish_member_cancel/2}
              ,{fun kapi_definition:set_required_headers/2, [?KEY_ACCOUNT_ID
                                                            ,?KEY_QUEUE_ID
                                                            ,?KEY_CALL_ID
                                                            ,<<"Reason">>
                                                            ]}
              ,{fun kapi_definition:set_optional_headers/2, [<<"Joined-Timestamp">>
                                                            ,<<"Cancelled-Timestamp">>
                                                            ]}
              ,{fun kapi_definition:set_values/2
               ,[{<<"Reason">>, ?CANCEL_REASONS}
                 | kapi_definition:event_type_headers(?CATEGORY, EventName)
                ]
               }
              ,{fun kapi_definition:set_types/2, [{?KEY_ACCOUNT_ID, fun is_binary/1}
                                                 ,{?KEY_QUEUE_ID, fun is_binary/1}
                                                 ,{?KEY_CALL_ID, fun is_binary/1}
                                                 ,{<<"Joined-Timestamp">>, fun is_integer/1}
                                                 ,{<<"Cancelled-Timestamp">>, fun is_integer/1}
                                                 ]}
              ],
    kapi_definition:setters(Setters).

%%------------------------------------------------------------------------------
%% @doc A waiting caller has been bridged to an agent.
%% @end
%%------------------------------------------------------------------------------
%%------------------------------------------------------------------------------
%% @doc A waiting caller is being offered: the dispatcher has started ringing
%% agents for them, and the offer's bridge is about to take the caller's
%% channel over from the callflow action holding it.
%%
%% The action reads two things from it. That the caller has somebody after
%% all, so the no-agent clock does not run while a phone rings for them; and
%% how long the ringing can last, `Offer-Timeout' being the ring timeout in
%% seconds, so that an offer whose end goes unheard does not pause that clock
%% for ever. The bridge's own completion on the caller's channel says how the
%% offer ended.
%% @end
%%------------------------------------------------------------------------------
-spec member_offer_definition() -> kapi_definition:api().
member_offer_definition() ->
    EventName = <<"member_offer">>,
    Setters = [{fun kapi_definition:set_name/2, EventName}
              ,{fun kapi_definition:set_friendly_name/2, <<"Queue Member Offered">>}
              ,{fun kapi_definition:set_description/2
               ,<<"A waiting caller is being offered to agents, whose phones are ringing">>
               }
              ,{fun kapi_definition:set_category/2, ?CATEGORY}
              ,{fun kapi_definition:set_build_fun/2, fun member_offer/1}
              ,{fun kapi_definition:set_validate_fun/2, fun member_offer_v/1}
              ,{fun kapi_definition:set_publish_fun/2, fun publish_member_offer/1}
              ,{fun kapi_definition:set_required_headers/2, [?KEY_ACCOUNT_ID
                                                            ,?KEY_QUEUE_ID
                                                            ,?KEY_CALL_ID
                                                            ,<<"Agent-IDs">>
                                                            ,<<"Offer-Timeout">>
                                                            ]}
              ,{fun kapi_definition:set_optional_headers/2, [<<"Joined-Timestamp">>]}
              ,{fun kapi_definition:set_values/2
               ,kapi_definition:event_type_headers(?CATEGORY, EventName)
               }
              ,{fun kapi_definition:set_types/2, [{?KEY_ACCOUNT_ID, fun is_binary/1}
                                                 ,{?KEY_QUEUE_ID, fun is_binary/1}
                                                 ,{?KEY_CALL_ID, fun is_binary/1}
                                                 ,{<<"Agent-IDs">>, fun kz_term:is_ne_binaries/1}
                                                 ,{<<"Offer-Timeout">>, fun is_integer/1}
                                                 ,{<<"Joined-Timestamp">>, fun is_integer/1}
                                                 ]}
              ],
    kapi_definition:setters(Setters).

-spec member_connected_definition() -> kapi_definition:api().
member_connected_definition() ->
    EventName = <<"member_connected">>,
    Setters = [{fun kapi_definition:set_name/2, EventName}
              ,{fun kapi_definition:set_friendly_name/2, <<"Queue Member Connected">>}
              ,{fun kapi_definition:set_description/2
               ,<<"A waiting caller has been connected to an agent">>
               }
              ,{fun kapi_definition:set_category/2, ?CATEGORY}
              ,{fun kapi_definition:set_build_fun/2, fun member_connected/1}
              ,{fun kapi_definition:set_validate_fun/2, fun member_connected_v/1}
              ,{fun kapi_definition:set_publish_fun/2, fun publish_member_connected/1}
              ,{fun kapi_definition:set_required_headers/2, [?KEY_ACCOUNT_ID
                                                            ,?KEY_QUEUE_ID
                                                            ,?KEY_CALL_ID
                                                            ,?KEY_AGENT_ID
                                                            ,<<"Agent-Call-ID">>
                                                            ,<<"Answered-Timestamp">>
                                                            ]}
              ,{fun kapi_definition:set_optional_headers/2, [<<"Joined-Timestamp">>]}
              ,{fun kapi_definition:set_values/2
               ,kapi_definition:event_type_headers(?CATEGORY, EventName)
               }
              ,{fun kapi_definition:set_types/2, [{?KEY_ACCOUNT_ID, fun is_binary/1}
                                                 ,{?KEY_QUEUE_ID, fun is_binary/1}
                                                 ,{?KEY_CALL_ID, fun is_binary/1}
                                                 ,{?KEY_AGENT_ID, fun is_binary/1}
                                                 ,{<<"Agent-Call-ID">>, fun is_binary/1}
                                                 ,{<<"Answered-Timestamp">>, fun is_integer/1}
                                                 ,{<<"Joined-Timestamp">>, fun is_integer/1}
                                                 ]}
              ],
    kapi_definition:setters(Setters).

%%------------------------------------------------------------------------------
%% @doc How a queue call ended.
%%
%% `Agent-ID' and `Agent-Call-ID' are optional because `failed' can happen
%% with no agent leg ever built.
%%
%% `queue_deleted' is the one result for a caller nobody connected: the
%% queue they waited in was deleted, the dispatcher took them out of it, and
%% the callflow action that hears this leaves on its `no_agents' branch.
%% @end
%%------------------------------------------------------------------------------
-spec member_result_definition() -> kapi_definition:api().
member_result_definition() ->
    EventName = <<"member_result">>,
    Setters = [{fun kapi_definition:set_name/2, EventName}
              ,{fun kapi_definition:set_friendly_name/2, <<"Queue Member Result">>}
              ,{fun kapi_definition:set_description/2, <<"How a queue call ended">>}
              ,{fun kapi_definition:set_category/2, ?CATEGORY}
              ,{fun kapi_definition:set_build_fun/2, fun member_result/1}
              ,{fun kapi_definition:set_validate_fun/2, fun member_result_v/1}
              ,{fun kapi_definition:set_publish_fun/2, fun publish_member_result/1}
              ,{fun kapi_definition:set_required_headers/2, [?KEY_ACCOUNT_ID
                                                            ,?KEY_QUEUE_ID
                                                            ,?KEY_CALL_ID
                                                            ,<<"Result">>
                                                            ,<<"Ended-Timestamp">>
                                                            ]}
              ,{fun kapi_definition:set_optional_headers/2, [?KEY_AGENT_ID
                                                            ,<<"Agent-Call-ID">>
                                                            ,<<"Joined-Timestamp">>
                                                            ]}
              ,{fun kapi_definition:set_values/2
               ,[{<<"Result">>, ?RESULTS}
                 | kapi_definition:event_type_headers(?CATEGORY, EventName)
                ]
               }
              ,{fun kapi_definition:set_types/2, [{?KEY_ACCOUNT_ID, fun is_binary/1}
                                                 ,{?KEY_QUEUE_ID, fun is_binary/1}
                                                 ,{?KEY_CALL_ID, fun is_binary/1}
                                                 ,{?KEY_AGENT_ID, fun is_binary/1}
                                                 ,{<<"Agent-Call-ID">>, fun is_binary/1}
                                                 ,{<<"Ended-Timestamp">>, fun is_integer/1}
                                                 ,{<<"Joined-Timestamp">>, fun is_integer/1}
                                                 ]}
              ],
    kapi_definition:setters(Setters).

%%------------------------------------------------------------------------------
%% @doc Where a waiting caller stands, published on every change of position
%% and on the announcement interval while they wait.
%%
%% It goes on the caller's own routing key, because the callflow action that
%% put them in the queue is what speaks the position to them; the wallboard
%% takes the same feed. `Agents-Available' rides along because the action's
%% `max_wait_time_with_no_agent' timer is decided by it and nothing else on
%% that key carries it. It is left out when the dispatcher cannot say --
%% the agents' activity unread, or the switches not answered yet -- and a
%% reader takes its absence as nothing new, never as zero. `Offered' says
%% whether a ring the action was told of by `member_offer' is still out:
%% false ends an action's belief in a ring whose end its channel never
%% showed.
%% @end
%%------------------------------------------------------------------------------
-spec member_position_definition() -> kapi_definition:api().
member_position_definition() ->
    EventName = <<"member_position">>,
    Setters = [{fun kapi_definition:set_name/2, EventName}
              ,{fun kapi_definition:set_friendly_name/2, <<"Queue Member Position">>}
              ,{fun kapi_definition:set_description/2
               ,<<"Where a waiting caller stands in their queue">>
               }
              ,{fun kapi_definition:set_category/2, ?CATEGORY}
              ,{fun kapi_definition:set_build_fun/2, fun member_position/1}
              ,{fun kapi_definition:set_validate_fun/2, fun member_position_v/1}
              ,{fun kapi_definition:set_publish_fun/2, fun publish_member_position/1}
              ,{fun kapi_definition:set_required_headers/2, [?KEY_ACCOUNT_ID
                                                            ,?KEY_QUEUE_ID
                                                            ,?KEY_CALL_ID
                                                            ,<<"Position">>
                                                            ,<<"Waiting">>
                                                            ,<<"Timestamp">>
                                                            ]}
              %% Who is waiting and where, so that a screen watching the
              %% queue can name the caller without a second lookup and
              %% without having seen them arrive.
              ,{fun kapi_definition:set_optional_headers/2, [<<"Agents-Available">>
                                                            ,<<"Caller-ID-Name">>
                                                            ,<<"Caller-ID-Number">>
                                                            ,<<"Joined-Timestamp">>
                                                            ,<<"Media-Node">>
                                                            ,<<"Offered">>
                                                            ]}
              ,{fun kapi_definition:set_values/2
               ,kapi_definition:event_type_headers(?CATEGORY, EventName)
               }
              ,{fun kapi_definition:set_types/2, [{?KEY_ACCOUNT_ID, fun is_binary/1}
                                                 ,{?KEY_QUEUE_ID, fun is_binary/1}
                                                 ,{?KEY_CALL_ID, fun is_binary/1}
                                                 ,{<<"Position">>, fun is_integer/1}
                                                 ,{<<"Waiting">>, fun is_integer/1}
                                                 ,{<<"Agents-Available">>, fun is_integer/1}
                                                 ,{<<"Timestamp">>, fun is_integer/1}
                                                 ,{<<"Caller-ID-Name">>, fun is_binary/1}
                                                 ,{<<"Caller-ID-Number">>, fun is_binary/1}
                                                 ,{<<"Joined-Timestamp">>, fun is_integer/1}
                                                 ,{<<"Media-Node">>, fun is_binary/1}
                                                 ,{<<"Offered">>, fun is_boolean/1}
                                                 ]}
              ],
    kapi_definition:setters(Setters).

%%------------------------------------------------------------------------------
%% @doc The call centre is done with a caller and hands them back to the
%% callflow action that sent them, which goes on into the flow `Branch'
%% names.
%%
%% Sent by the caller's own actor on the node holding the account's shard,
%% straight to the action's Controller-Queue (`publish_member_continue/2'),
%% only once the channel has run every command the actor sent it. The
%% action answers `member_continuing' to `Reply-To'; an actor that hears
%% nothing asks again, and after that resumes the caller elsewhere.
%% `Handoff-ID' is the passage's own, from its `member_call', and the action
%% takes a continue for no other.
%% @end
%%------------------------------------------------------------------------------
-spec member_continue_definition() -> kapi_definition:api().
member_continue_definition() ->
    EventName = <<"member_continue">>,
    Setters = [{fun kapi_definition:set_name/2, EventName}
              ,{fun kapi_definition:set_friendly_name/2, <<"Queue Member Continue">>}
              ,{fun kapi_definition:set_description/2
               ,<<"A caller the queue is done with, handed back to their callflow on a branch">>
               }
              ,{fun kapi_definition:set_category/2, ?CATEGORY}
              ,{fun kapi_definition:set_build_fun/2, fun member_continue/1}
              ,{fun kapi_definition:set_validate_fun/2, fun member_continue_v/1}
              ,{fun kapi_definition:set_publish_fun/2, fun publish_member_continue/2}
              ,{fun kapi_definition:set_required_headers/2, [?KEY_ACCOUNT_ID
                                                            ,?KEY_QUEUE_ID
                                                            ,?KEY_CALL_ID
                                                            ,<<"Handoff-ID">>
                                                            ,<<"Branch">>
                                                            ]}
              ,{fun kapi_definition:set_optional_headers/2, [<<"Reply-To">>]}
              ,{fun kapi_definition:set_values/2
               ,kapi_definition:event_type_headers(?CATEGORY, EventName)
               }
              ,{fun kapi_definition:set_types/2, [{?KEY_ACCOUNT_ID, fun is_binary/1}
                                                 ,{?KEY_QUEUE_ID, fun is_binary/1}
                                                 ,{?KEY_CALL_ID, fun is_binary/1}
                                                 ,{<<"Handoff-ID">>, fun is_binary/1}
                                                 ,{<<"Branch">>, fun is_binary/1}
                                                 ,{<<"Reply-To">>, fun is_binary/1}
                                                 ]}
              ],
    kapi_definition:setters(Setters).

%%------------------------------------------------------------------------------
%% @doc The callflow action has the caller back: its answer to a
%% `member_continue', to that message's `Reply-To'.
%% @end
%%------------------------------------------------------------------------------
-spec member_continuing_definition() -> kapi_definition:api().
member_continuing_definition() ->
    EventName = <<"member_continuing">>,
    Setters = [{fun kapi_definition:set_name/2, EventName}
              ,{fun kapi_definition:set_friendly_name/2, <<"Queue Member Continuing">>}
              ,{fun kapi_definition:set_description/2
               ,<<"The callflow has a caller the queue handed back">>
               }
              ,{fun kapi_definition:set_category/2, ?CATEGORY}
              ,{fun kapi_definition:set_build_fun/2, fun member_continuing/1}
              ,{fun kapi_definition:set_validate_fun/2, fun member_continuing_v/1}
              ,{fun kapi_definition:set_publish_fun/2, fun publish_member_continuing/2}
              ,{fun kapi_definition:set_required_headers/2, [?KEY_CALL_ID
                                                            ,<<"Handoff-ID">>
                                                            ]}
              ,{fun kapi_definition:set_optional_headers/2, []}
              ,{fun kapi_definition:set_values/2
               ,kapi_definition:event_type_headers(?CATEGORY, EventName)
               }
              ,{fun kapi_definition:set_types/2, [{?KEY_CALL_ID, fun is_binary/1}
                                                 ,{<<"Handoff-ID">>, fun is_binary/1}
                                                 ]}
              ],
    kapi_definition:setters(Setters).

%%------------------------------------------------------------------------------
%% @doc An agent's availability changed: what it is now, what it was, and who
%% or what changed it. `Break-Ends' is when a break that has an end ends by
%% itself, in Gregorian seconds.
%% @end
%%------------------------------------------------------------------------------
-spec agent_availability_definition() -> kapi_definition:api().
agent_availability_definition() ->
    EventName = <<"agent_availability">>,
    Setters = [{fun kapi_definition:set_name/2, EventName}
              ,{fun kapi_definition:set_friendly_name/2, <<"Agent Availability">>}
              ,{fun kapi_definition:set_description/2
               ,<<"An agent's chosen availability has changed">>
               }
              ,{fun kapi_definition:set_category/2, ?CATEGORY}
              ,{fun kapi_definition:set_build_fun/2, fun agent_availability/1}
              ,{fun kapi_definition:set_validate_fun/2, fun agent_availability_v/1}
              ,{fun kapi_definition:set_publish_fun/2, fun publish_agent_availability/1}
              ,{fun kapi_definition:set_required_headers/2, [?KEY_ACCOUNT_ID
                                                            ,?KEY_AGENT_ID
                                                            ,<<"Availability">>
                                                            ,<<"Source">>
                                                            ,<<"Timestamp">>
                                                            ]}
              ,{fun kapi_definition:set_optional_headers/2, [<<"Previous">>
                                                            ,<<"Break-Ends">>
                                                            ]}
              ,{fun kapi_definition:set_values/2
               ,[{<<"Availability">>, ?AVAILABILITIES}
                ,{<<"Previous">>, ?AVAILABILITIES}
                ,{<<"Source">>, ?AVAILABILITY_SOURCES}
                 | kapi_definition:event_type_headers(?CATEGORY, EventName)
                ]
               }
              ,{fun kapi_definition:set_types/2, [{?KEY_ACCOUNT_ID, fun is_binary/1}
                                                 ,{?KEY_AGENT_ID, fun is_binary/1}
                                                 ,{<<"Timestamp">>, fun is_integer/1}
                                                 ,{<<"Break-Ends">>, fun is_integer/1}
                                                 ]}
              ],
    kapi_definition:setters(Setters).

%%------------------------------------------------------------------------------
%% @doc What an agent's phones are doing. Derived from channel events, not
%% chosen, and it covers every call the user is on, queue or not:
%% `Queue-Call' says which kind this one is.
%% @end
%%------------------------------------------------------------------------------
-spec agent_activity_definition() -> kapi_definition:api().
agent_activity_definition() ->
    EventName = <<"agent_activity">>,
    Setters = [{fun kapi_definition:set_name/2, EventName}
              ,{fun kapi_definition:set_friendly_name/2, <<"Agent Activity">>}
              ,{fun kapi_definition:set_description/2
               ,<<"An agent's derived activity has changed">>
               }
              ,{fun kapi_definition:set_category/2, ?CATEGORY}
              ,{fun kapi_definition:set_build_fun/2, fun agent_activity/1}
              ,{fun kapi_definition:set_validate_fun/2, fun agent_activity_v/1}
              ,{fun kapi_definition:set_publish_fun/2, fun publish_agent_activity/1}
              ,{fun kapi_definition:set_required_headers/2, [?KEY_ACCOUNT_ID
                                                            ,?KEY_AGENT_ID
                                                            ,<<"Activity">>
                                                            ,<<"Timestamp">>
                                                            ]}
              ,{fun kapi_definition:set_optional_headers/2, [?KEY_CALL_ID
                                                            ,<<"Queue-Call">>
                                                            ]}
              ,{fun kapi_definition:set_values/2
               ,[{<<"Activity">>, ?ACTIVITIES}
                 | kapi_definition:event_type_headers(?CATEGORY, EventName)
                ]
               }
              ,{fun kapi_definition:set_types/2, [{?KEY_ACCOUNT_ID, fun is_binary/1}
                                                 ,{?KEY_AGENT_ID, fun is_binary/1}
                                                 ,{?KEY_CALL_ID, fun is_binary/1}
                                                 ,{<<"Queue-Call">>, fun is_boolean/1}
                                                 ,{<<"Timestamp">>, fun is_integer/1}
                                                 ]}
              ],
    kapi_definition:setters(Setters).

%%------------------------------------------------------------------------------
%% @doc A caller is being offered to an agent, whose phones are now ringing.
%% @end
%%------------------------------------------------------------------------------
-spec agent_offer_definition() -> kapi_definition:api().
agent_offer_definition() ->
    EventName = <<"agent_offer">>,
    Setters = [{fun kapi_definition:set_name/2, EventName}
              ,{fun kapi_definition:set_friendly_name/2, <<"Agent Offer">>}
              ,{fun kapi_definition:set_description/2
               ,<<"A waiting caller is being offered to an agent">>
               }
              ,{fun kapi_definition:set_category/2, ?CATEGORY}
              ,{fun kapi_definition:set_build_fun/2, fun agent_offer/1}
              ,{fun kapi_definition:set_validate_fun/2, fun agent_offer_v/1}
              ,{fun kapi_definition:set_publish_fun/2, fun publish_agent_offer/1}
              ,{fun kapi_definition:set_required_headers/2, [?KEY_ACCOUNT_ID
                                                            ,?KEY_QUEUE_ID
                                                            ,?KEY_AGENT_ID
                                                            ,?KEY_CALL_ID
                                                            ,<<"Offer-Timeout">>
                                                            ]}
              ,{fun kapi_definition:set_optional_headers/2, []}
              ,{fun kapi_definition:set_values/2
               ,kapi_definition:event_type_headers(?CATEGORY, EventName)
               }
              ,{fun kapi_definition:set_types/2, [{?KEY_ACCOUNT_ID, fun is_binary/1}
                                                 ,{?KEY_QUEUE_ID, fun is_binary/1}
                                                 ,{?KEY_AGENT_ID, fun is_binary/1}
                                                 ,{?KEY_CALL_ID, fun is_binary/1}
                                                 ,{<<"Offer-Timeout">>, fun is_integer/1}
                                                 ]}
              ],
    kapi_definition:setters(Setters).

%%------------------------------------------------------------------------------
%% @doc An agent answered the caller they were offered.
%% @end
%%------------------------------------------------------------------------------
-spec agent_answered_definition() -> kapi_definition:api().
agent_answered_definition() ->
    EventName = <<"agent_answered">>,
    Setters = [{fun kapi_definition:set_name/2, EventName}
              ,{fun kapi_definition:set_friendly_name/2, <<"Agent Answered">>}
              ,{fun kapi_definition:set_description/2
               ,<<"An agent answered a queue call">>
               }
              ,{fun kapi_definition:set_category/2, ?CATEGORY}
              ,{fun kapi_definition:set_build_fun/2, fun agent_answered/1}
              ,{fun kapi_definition:set_validate_fun/2, fun agent_answered_v/1}
              ,{fun kapi_definition:set_publish_fun/2, fun publish_agent_answered/1}
              ,{fun kapi_definition:set_required_headers/2, [?KEY_ACCOUNT_ID
                                                            ,?KEY_QUEUE_ID
                                                            ,?KEY_AGENT_ID
                                                            ,?KEY_CALL_ID
                                                            ,<<"Agent-Call-ID">>
                                                            ,<<"Answered-Timestamp">>
                                                            ]}
              ,{fun kapi_definition:set_optional_headers/2, []}
              ,{fun kapi_definition:set_values/2
               ,kapi_definition:event_type_headers(?CATEGORY, EventName)
               }
              ,{fun kapi_definition:set_types/2, [{?KEY_ACCOUNT_ID, fun is_binary/1}
                                                 ,{?KEY_QUEUE_ID, fun is_binary/1}
                                                 ,{?KEY_AGENT_ID, fun is_binary/1}
                                                 ,{?KEY_CALL_ID, fun is_binary/1}
                                                 ,{<<"Agent-Call-ID">>, fun is_binary/1}
                                                 ,{<<"Answered-Timestamp">>, fun is_integer/1}
                                                 ]}
              ],
    kapi_definition:setters(Setters).

%%------------------------------------------------------------------------------
%% @doc An agent's queue call ended and their wrap-up has started.
%% `Wrapup-Ends' is when they become available again.
%% @end
%%------------------------------------------------------------------------------
-spec agent_wrapup_definition() -> kapi_definition:api().
agent_wrapup_definition() ->
    EventName = <<"agent_wrapup">>,
    Setters = [{fun kapi_definition:set_name/2, EventName}
              ,{fun kapi_definition:set_friendly_name/2, <<"Agent Wrapup">>}
              ,{fun kapi_definition:set_description/2
               ,<<"An agent has entered wrap-up after a queue call">>
               }
              ,{fun kapi_definition:set_category/2, ?CATEGORY}
              ,{fun kapi_definition:set_build_fun/2, fun agent_wrapup/1}
              ,{fun kapi_definition:set_validate_fun/2, fun agent_wrapup_v/1}
              ,{fun kapi_definition:set_publish_fun/2, fun publish_agent_wrapup/1}
              ,{fun kapi_definition:set_required_headers/2, [?KEY_ACCOUNT_ID
                                                            ,?KEY_QUEUE_ID
                                                            ,?KEY_AGENT_ID
                                                            ,<<"Wrapup-Ends">>
                                                            ,<<"Timestamp">>
                                                            ]}
              ,{fun kapi_definition:set_optional_headers/2, [?KEY_CALL_ID]}
              ,{fun kapi_definition:set_values/2
               ,kapi_definition:event_type_headers(?CATEGORY, EventName)
               }
              ,{fun kapi_definition:set_types/2, [{?KEY_ACCOUNT_ID, fun is_binary/1}
                                                 ,{?KEY_QUEUE_ID, fun is_binary/1}
                                                 ,{?KEY_AGENT_ID, fun is_binary/1}
                                                 ,{?KEY_CALL_ID, fun is_binary/1}
                                                 ,{<<"Wrapup-Ends">>, fun is_integer/1}
                                                 ,{<<"Timestamp">>, fun is_integer/1}
                                                 ]}
              ],
    kapi_definition:setters(Setters).

%%------------------------------------------------------------------------------
%% @doc What one queue looks like right now, published whenever it changes.
%% The wallboard and the supervisor views run off this rather than polling.
%% @end
%%------------------------------------------------------------------------------
-spec queue_stats_definition() -> kapi_definition:api().
queue_stats_definition() ->
    EventName = <<"queue_stats">>,
    Setters = [{fun kapi_definition:set_name/2, EventName}
              ,{fun kapi_definition:set_friendly_name/2, <<"Queue Stats">>}
              ,{fun kapi_definition:set_description/2
               ,<<"A queue's waiting count, longest wait and available agents">>
               }
              ,{fun kapi_definition:set_category/2, ?CATEGORY}
              ,{fun kapi_definition:set_build_fun/2, fun queue_stats/1}
              ,{fun kapi_definition:set_validate_fun/2, fun queue_stats_v/1}
              ,{fun kapi_definition:set_publish_fun/2, fun publish_queue_stats/1}
              ,{fun kapi_definition:set_required_headers/2, [?KEY_ACCOUNT_ID
                                                            ,?KEY_QUEUE_ID
                                                            ,<<"Waiting">>
                                                            ,<<"Longest-Wait">>
                                                            ,<<"Agents-Available">>
                                                            ,<<"Timestamp">>
                                                            ]}
              ,{fun kapi_definition:set_optional_headers/2, []}
              ,{fun kapi_definition:set_values/2
               ,kapi_definition:event_type_headers(?CATEGORY, EventName)
               }
              ,{fun kapi_definition:set_types/2, [{?KEY_ACCOUNT_ID, fun is_binary/1}
                                                 ,{?KEY_QUEUE_ID, fun is_binary/1}
                                                 ,{<<"Waiting">>, fun is_integer/1}
                                                 ,{<<"Longest-Wait">>, fun is_integer/1}
                                                 ,{<<"Agents-Available">>, fun is_integer/1}
                                                 ,{<<"Timestamp">>, fun is_integer/1}
                                                 ]}
              ],
    kapi_definition:setters(Setters).

%%------------------------------------------------------------------------------
%% @doc Ask for an account's live call center state, optionally for one queue.
%% @end
%%------------------------------------------------------------------------------
-spec status_req_definition() -> kapi_definition:api().
status_req_definition() ->
    EventName = <<"status_req">>,
    Setters = [{fun kapi_definition:set_name/2, EventName}
              ,{fun kapi_definition:set_friendly_name/2, <<"Call Center Status Request">>}
              ,{fun kapi_definition:set_description/2
               ,<<"Ask for an account's live queue and agent state">>
               }
              ,{fun kapi_definition:set_category/2, ?CATEGORY}
              ,{fun kapi_definition:set_build_fun/2, fun status_req/1}
              ,{fun kapi_definition:set_validate_fun/2, fun status_req_v/1}
              ,{fun kapi_definition:set_publish_fun/2, fun publish_status_req/1}
              ,{fun kapi_definition:set_required_headers/2, [?KEY_ACCOUNT_ID]}
              ,{fun kapi_definition:set_optional_headers/2, [?KEY_QUEUE_ID]}
              ,{fun kapi_definition:set_values/2
               ,kapi_definition:event_type_headers(?CATEGORY, EventName)
               }
              ,{fun kapi_definition:set_types/2, [{?KEY_ACCOUNT_ID, fun is_binary/1}
                                                 ,{?KEY_QUEUE_ID, fun is_binary/1}
                                                 ]}
              ],
    kapi_definition:setters(Setters).

%%------------------------------------------------------------------------------
%% @doc One node's answer to a status request.
%%
%% `Shard' and `Node' say who answered. A node that does not hold the
%% account's shard says nothing at all, and the requester collects with a
%% count of one: an answer means somebody is dispatching, and a timeout with
%% no answers means nobody is.
%%
%% The answer must carry the request's `Msg-ID'. `kz_amqp_worker' matches
%% responses to the request it is waiting on by that field and silently
%% ignores the rest, so an answer without it reaches the requester's queue
%% and is dropped -- which looks exactly like nobody answering.
%%
%% Each entry in `Queues' names its queue and then says the same thing twice,
%% for its two readers: `Waiting' and `Agents' are the lists a screen draws,
%% and `Waiting-Count' and `Agents-Available' are the numbers the callflow
%% action decides on -- whether the queue is full, and whether anybody could
%% take the caller.
%%
%% `On-Queue-Call' lists the agents on a queue call in the account, whichever
%% queue it came from: what a login lamp probe answered on another node needs
%% to show `early'.
%% @end
%%------------------------------------------------------------------------------
-spec status_resp_definition() -> kapi_definition:api().
status_resp_definition() ->
    EventName = <<"status_resp">>,
    Setters = [{fun kapi_definition:set_name/2, EventName}
              ,{fun kapi_definition:set_friendly_name/2, <<"Call Center Status Response">>}
              ,{fun kapi_definition:set_description/2
               ,<<"One node's view of an account's live queue and agent state">>
               }
              ,{fun kapi_definition:set_category/2, ?CATEGORY}
              ,{fun kapi_definition:set_build_fun/2, fun status_resp/1}
              ,{fun kapi_definition:set_validate_fun/2, fun status_resp_v/1}
              ,{fun kapi_definition:set_publish_fun/2, fun publish_status_resp/2}
              ,{fun kapi_definition:set_required_headers/2, [?KEY_ACCOUNT_ID
                                                            ,<<"Queues">>
                                                            ]}
              ,{fun kapi_definition:set_optional_headers/2, [<<"Node">>
                                                            ,<<"On-Queue-Call">>
                                                            ,<<"Shard">>
                                                            ]}
              ,{fun kapi_definition:set_values/2
               ,kapi_definition:event_type_headers(?CATEGORY, EventName)
               }
              ,{fun kapi_definition:set_types/2, [{?KEY_ACCOUNT_ID, fun is_binary/1}
                                                 ,{<<"Node">>, fun is_binary/1}
                                                 ,{<<"On-Queue-Call">>, fun is_list/1}
                                                 ,{<<"Shard">>, fun is_integer/1}
                                                 ,{<<"Queues">>, fun is_list/1}
                                                 ]}
              ],
    kapi_definition:setters(Setters).

%%------------------------------------------------------------------------------
%% @doc A supervisor asks for a waiting caller to be rung through to their
%% own phones.
%%
%% Crossbar sends it once it has checked the request: the call is the
%% account's, and the device or user is the account's with a phone that
%% rings. `Supervisor-ID' is who answers -- the user, the owner of the device
%% named, or the device itself when nobody owns it -- and `Device-IDs' the
%% phones to ring. Only the node dispatching the account answers, as for a
%% status request. `Deadline-Ms' is the system time, in Unix milliseconds,
%% at which the requester stops waiting: nothing is rung for a request read
%% after it.
%% @end
%%------------------------------------------------------------------------------
-spec pickup_req_definition() -> kapi_definition:api().
pickup_req_definition() ->
    EventName = <<"pickup_req">>,
    Setters = [{fun kapi_definition:set_name/2, EventName}
              ,{fun kapi_definition:set_friendly_name/2, <<"Call Center Pickup Request">>}
              ,{fun kapi_definition:set_description/2
               ,<<"Ring a supervisor's own phones for a caller waiting in a queue">>
               }
              ,{fun kapi_definition:set_category/2, ?CATEGORY}
              ,{fun kapi_definition:set_build_fun/2, fun pickup_req/1}
              ,{fun kapi_definition:set_validate_fun/2, fun pickup_req_v/1}
              ,{fun kapi_definition:set_publish_fun/2, fun publish_pickup_req/1}
              ,{fun kapi_definition:set_required_headers/2, [?KEY_ACCOUNT_ID
                                                            ,?KEY_QUEUE_ID
                                                            ,?KEY_CALL_ID
                                                            ,<<"Supervisor-ID">>
                                                            ,<<"Target-Type">>
                                                            ,<<"Target-ID">>
                                                            ,<<"Device-IDs">>
                                                            ]}
              ,{fun kapi_definition:set_optional_headers/2, [<<"Deadline-Ms">>]}
              ,{fun kapi_definition:set_values/2
               ,[{<<"Target-Type">>, [<<"device">>, <<"user">>]}
                 | kapi_definition:event_type_headers(?CATEGORY, EventName)
                ]
               }
              ,{fun kapi_definition:set_types/2, [{?KEY_ACCOUNT_ID, fun is_binary/1}
                                                 ,{?KEY_QUEUE_ID, fun is_binary/1}
                                                 ,{?KEY_CALL_ID, fun is_binary/1}
                                                 ,{<<"Supervisor-ID">>, fun is_binary/1}
                                                 ,{<<"Target-ID">>, fun is_binary/1}
                                                 ,{<<"Device-IDs">>, fun kz_term:is_ne_binaries/1}
                                                 ,{<<"Deadline-Ms">>, fun is_integer/1}
                                                 ]}
              ],
    kapi_definition:setters(Setters).

%%------------------------------------------------------------------------------
%% @doc What the node dispatching the account did about a pickup.
%%
%% `ringing' is the only one that rang anything, for `Offer-Timeout'
%% seconds. The rest say why not: nobody with that call id is waiting in the
%% queue, an agent or another supervisor is being rung for the caller, the
%% supervisor is ringing for or talking to another caller of the account,
%% the ring could not be started, or the request came after the requester
%% had stopped waiting. Like a status answer it carries the request's
%% `Msg-ID' and goes to the requester's own queue.
%% @end
%%------------------------------------------------------------------------------
-spec pickup_resp_definition() -> kapi_definition:api().
pickup_resp_definition() ->
    EventName = <<"pickup_resp">>,
    Setters = [{fun kapi_definition:set_name/2, EventName}
              ,{fun kapi_definition:set_friendly_name/2, <<"Call Center Pickup Response">>}
              ,{fun kapi_definition:set_description/2
               ,<<"Whether a supervisor's phones are ringing for a waiting caller">>
               }
              ,{fun kapi_definition:set_category/2, ?CATEGORY}
              ,{fun kapi_definition:set_build_fun/2, fun pickup_resp/1}
              ,{fun kapi_definition:set_validate_fun/2, fun pickup_resp_v/1}
              ,{fun kapi_definition:set_publish_fun/2, fun publish_pickup_resp/2}
              ,{fun kapi_definition:set_required_headers/2, [?KEY_ACCOUNT_ID
                                                            ,?KEY_CALL_ID
                                                            ,<<"Result">>
                                                            ]}
              ,{fun kapi_definition:set_optional_headers/2, [<<"Node">>
                                                            ,<<"Offer-Timeout">>
                                                            ,<<"Reason">>
                                                            ]}
              ,{fun kapi_definition:set_values/2
               ,[{<<"Result">>, ?PICKUP_RESULTS}
                 | kapi_definition:event_type_headers(?CATEGORY, EventName)
                ]
               }
              ,{fun kapi_definition:set_types/2, [{?KEY_ACCOUNT_ID, fun is_binary/1}
                                                 ,{?KEY_CALL_ID, fun is_binary/1}
                                                 ,{<<"Node">>, fun is_binary/1}
                                                 ,{<<"Offer-Timeout">>, fun is_integer/1}
                                                 ,{<<"Reason">>, fun is_binary/1}
                                                 ]}
              ],
    kapi_definition:setters(Setters).

%%%=============================================================================
%%% Builders and validators
%%%=============================================================================

-spec member_call(kz_term:api_terms()) -> kz_api:api_formatter_return().
member_call(Req) -> kapi_definition:build_message(Req, member_call_definition()).

-spec member_call_v(kz_term:api_terms()) -> boolean().
member_call_v(Req) -> kapi_definition:validate(Req, member_call_definition()).

-spec member_cancel(kz_term:api_terms()) -> kz_api:api_formatter_return().
member_cancel(Req) -> kapi_definition:build_message(Req, member_cancel_definition()).

-spec member_cancel_v(kz_term:api_terms()) -> boolean().
member_cancel_v(Req) -> kapi_definition:validate(Req, member_cancel_definition()).

-spec member_offer(kz_term:api_terms()) -> kz_api:api_formatter_return().
member_offer(Req) -> kapi_definition:build_message(Req, member_offer_definition()).

-spec member_offer_v(kz_term:api_terms()) -> boolean().
member_offer_v(Req) -> kapi_definition:validate(Req, member_offer_definition()).

-spec member_connected(kz_term:api_terms()) -> kz_api:api_formatter_return().
member_connected(Req) -> kapi_definition:build_message(Req, member_connected_definition()).

-spec member_connected_v(kz_term:api_terms()) -> boolean().
member_connected_v(Req) -> kapi_definition:validate(Req, member_connected_definition()).

-spec member_result(kz_term:api_terms()) -> kz_api:api_formatter_return().
member_result(Req) -> kapi_definition:build_message(Req, member_result_definition()).

-spec member_result_v(kz_term:api_terms()) -> boolean().
member_result_v(Req) -> kapi_definition:validate(Req, member_result_definition()).

-spec member_position(kz_term:api_terms()) -> kz_api:api_formatter_return().
member_position(Req) -> kapi_definition:build_message(Req, member_position_definition()).

-spec member_position_v(kz_term:api_terms()) -> boolean().
member_position_v(Req) -> kapi_definition:validate(Req, member_position_definition()).

-spec member_continue(kz_term:api_terms()) -> kz_api:api_formatter_return().
member_continue(Req) -> kapi_definition:build_message(Req, member_continue_definition()).

-spec member_continue_v(kz_term:api_terms()) -> boolean().
member_continue_v(Req) -> kapi_definition:validate(Req, member_continue_definition()).

-spec member_continuing(kz_term:api_terms()) -> kz_api:api_formatter_return().
member_continuing(Req) -> kapi_definition:build_message(Req, member_continuing_definition()).

-spec member_continuing_v(kz_term:api_terms()) -> boolean().
member_continuing_v(Req) -> kapi_definition:validate(Req, member_continuing_definition()).

-spec agent_availability(kz_term:api_terms()) -> kz_api:api_formatter_return().
agent_availability(Req) -> kapi_definition:build_message(Req, agent_availability_definition()).

-spec agent_availability_v(kz_term:api_terms()) -> boolean().
agent_availability_v(Req) -> kapi_definition:validate(Req, agent_availability_definition()).

-spec agent_activity(kz_term:api_terms()) -> kz_api:api_formatter_return().
agent_activity(Req) -> kapi_definition:build_message(Req, agent_activity_definition()).

-spec agent_activity_v(kz_term:api_terms()) -> boolean().
agent_activity_v(Req) -> kapi_definition:validate(Req, agent_activity_definition()).

-spec agent_offer(kz_term:api_terms()) -> kz_api:api_formatter_return().
agent_offer(Req) -> kapi_definition:build_message(Req, agent_offer_definition()).

-spec agent_offer_v(kz_term:api_terms()) -> boolean().
agent_offer_v(Req) -> kapi_definition:validate(Req, agent_offer_definition()).

-spec agent_answered(kz_term:api_terms()) -> kz_api:api_formatter_return().
agent_answered(Req) -> kapi_definition:build_message(Req, agent_answered_definition()).

-spec agent_answered_v(kz_term:api_terms()) -> boolean().
agent_answered_v(Req) -> kapi_definition:validate(Req, agent_answered_definition()).

-spec agent_wrapup(kz_term:api_terms()) -> kz_api:api_formatter_return().
agent_wrapup(Req) -> kapi_definition:build_message(Req, agent_wrapup_definition()).

-spec agent_wrapup_v(kz_term:api_terms()) -> boolean().
agent_wrapup_v(Req) -> kapi_definition:validate(Req, agent_wrapup_definition()).

-spec queue_stats(kz_term:api_terms()) -> kz_api:api_formatter_return().
queue_stats(Req) -> kapi_definition:build_message(Req, queue_stats_definition()).

-spec queue_stats_v(kz_term:api_terms()) -> boolean().
queue_stats_v(Req) -> kapi_definition:validate(Req, queue_stats_definition()).

-spec status_req(kz_term:api_terms()) -> kz_api:api_formatter_return().
status_req(Req) -> kapi_definition:build_message(Req, status_req_definition()).

-spec status_req_v(kz_term:api_terms()) -> boolean().
status_req_v(Req) -> kapi_definition:validate(Req, status_req_definition()).

-spec status_resp(kz_term:api_terms()) -> kz_api:api_formatter_return().
status_resp(Req) -> kapi_definition:build_message(Req, status_resp_definition()).

-spec status_resp_v(kz_term:api_terms()) -> boolean().
status_resp_v(Req) -> kapi_definition:validate(Req, status_resp_definition()).

-spec pickup_req(kz_term:api_terms()) -> kz_api:api_formatter_return().
pickup_req(Req) -> kapi_definition:build_message(Req, pickup_req_definition()).

-spec pickup_req_v(kz_term:api_terms()) -> boolean().
pickup_req_v(Req) -> kapi_definition:validate(Req, pickup_req_definition()).

-spec pickup_resp(kz_term:api_terms()) -> kz_api:api_formatter_return().
pickup_resp(Req) -> kapi_definition:build_message(Req, pickup_resp_definition()).

-spec pickup_resp_v(kz_term:api_terms()) -> boolean().
pickup_resp_v(Req) -> kapi_definition:validate(Req, pickup_resp_definition()).

%%%=============================================================================
%%% Shards
%%%=============================================================================

%%------------------------------------------------------------------------------
%% @doc The member queue of a shard: `callcenter.member.<shard>'.
%%
%% Which shard an account is in, how many there are and how the queue is
%% declared are the application's own, in `callcenter/shards': the node that
%% publishes a member and the node that consumes it both run it.
%% @end
%%------------------------------------------------------------------------------
-spec member_queue(non_neg_integer() | kz_term:ne_binary()) -> kz_term:ne_binary().
member_queue(Shard) when is_integer(Shard) ->
    <<"callcenter.member.", (integer_to_binary(Shard))/binary>>;
member_queue(Shard) ->
    <<"callcenter.member.", (kz_term:to_binary(Shard))/binary>>.

%%%=============================================================================
%%% Routing keys
%%%=============================================================================

-spec exchange() -> kz_term:ne_binary().
exchange() -> ?EXCHANGE.

-spec exchange_type() -> kz_term:ne_binary().
exchange_type() -> ?EXCHANGE_TYPE.

%%------------------------------------------------------------------------------
%% @doc The routing key of one family's events: `callcenter.<family>.<account>.<id>'.
%%
%% The one place the key is spelled. The publishers here, the bindings
%% `bind_q/2' makes, `bh_callcenter''s subscriptions and `blackhole_listener''s
%% lookup of who subscribed all build it through this, so the socket, the
%% binding and the published event cannot disagree about a key.
%%
%% `Family' is `call', `agent' or `queue', as an atom or a binary.
%%
%% The account and the id are each one word of the key, whatever they hold:
%% `segment/1' escapes them. An account or queue id is hex and comes through
%% as it is; a call id is whatever the switch or the far end chose, and a SIP
%% Call-ID such as `abc@10.0.0.1' would otherwise be four words, which no
%% `callcenter.call.*.*' binding matches.
%% @end
%%------------------------------------------------------------------------------
-spec routing_key(atom() | kz_term:ne_binary(), kz_term:api_binary(), kz_term:api_binary()) ->
          kz_term:ne_binary().
routing_key(Family, AccountId, Id) ->
    <<"callcenter.", (family_name(Family))/binary
      ,".", (segment(AccountId))/binary
      ,".", (segment(Id))/binary
    >>.

-spec call_routing_key(kz_term:api_ne_binary(), kz_term:api_ne_binary()) -> kz_term:ne_binary().
call_routing_key(AccountId, CallId) -> routing_key('call', AccountId, CallId).

-spec agent_routing_key(kz_term:api_ne_binary(), kz_term:api_ne_binary()) -> kz_term:ne_binary().
agent_routing_key(AccountId, AgentId) -> routing_key('agent', AccountId, AgentId).

-spec queue_routing_key(kz_term:api_ne_binary(), kz_term:api_ne_binary()) -> kz_term:ne_binary().
queue_routing_key(AccountId, QueueId) -> routing_key('queue', AccountId, QueueId).

-spec status_routing_key(kz_term:api_ne_binary()) -> kz_term:ne_binary().
status_routing_key(AccountId) ->
    <<"callcenter.status.", (segment(AccountId))/binary>>.

%% A key of its own and not the status key: a node that only knows status
%% requests, during a rolling upgrade, would answer a pickup on that key with
%% a status and the requester would take it for the pickup's answer.
-spec pickup_routing_key(kz_term:api_ne_binary()) -> kz_term:ne_binary().
pickup_routing_key(AccountId) ->
    <<"callcenter.pickup.", (segment(AccountId))/binary>>.

%%------------------------------------------------------------------------------
%% @doc The keys a subscriber to an event may have used: its family's key
%% with every id, and with this event's own.
%%
%% The family is not on the event, only its name is: `queue_stats' is the
%% queue's, every `agent_' event is the agent's, and anything else is looked
%% for under the call.
%% @end
%%------------------------------------------------------------------------------
-spec event_routing_keys(kz_term:api_binary(), kz_json:object()) -> kz_term:ne_binaries().
event_routing_keys(EventName, JObj) ->
    {Family, Id} = event_family(EventName, JObj),
    AccountId = account_id(JObj),
    [routing_key(Family, AccountId, <<"*">>)
    ,routing_key(Family, AccountId, Id)
    ].

-spec event_family(kz_term:api_binary(), kz_json:object()) -> {atom(), kz_term:api_ne_binary()}.
event_family(<<"queue_stats">>, JObj) -> {'queue', queue_id(JObj)};
event_family(<<"agent_", _/binary>>, JObj) -> {'agent', agent_id(JObj)};
event_family(_EventName, JObj) -> {'call', call_id(JObj)}.

-spec family_name(atom() | kz_term:ne_binary()) -> kz_term:ne_binary().
family_name(Family) when is_atom(Family) -> atom_to_binary(Family, 'utf8');
family_name(Family) when is_binary(Family) -> Family.

%%------------------------------------------------------------------------------
%% @doc One word of a routing key: an account, agent, queue or call id.
%%
%% An absent id binds to every id: publishers always pass a real one, and it
%% is `bind_q/2' that leaves them out. `*' and `#' stay the wildcards they
%% are. Anything else is escaped as `kz_amqp_util:encode/1' escapes a call id
%% in `kapi_call''s keys, so a call id is spelled the same on both exchanges:
%% letters, digits, `-', `~' and `_' as they are, a space as `+', and every
%% other byte -- the `.' that separates words, the `@' of a SIP Call-ID, a
%% `*' or `#' inside an id, and `%' itself -- as `%XX'.
%%
%% Written out here rather than called, for the reason at the top of the
%% module and so that `bh_callcenter' and the tests build a key with none of
%% the platform loaded. Publisher and binder agree because both come through
%% here; the escape only has to be the same function on both ends.
%% @end
%%------------------------------------------------------------------------------
-spec segment(kz_term:api_binary()) -> kz_term:ne_binary().
segment('undefined') -> <<"*">>;
segment(<<>>) -> <<"*">>;
segment(<<"*">>) -> <<"*">>;
segment(<<"#">>) -> <<"#">>;
segment(Value) when is_binary(Value) -> << <<(escape(C))/binary>> || <<C>> <= Value >>;
segment(Value) when is_integer(Value) -> segment(integer_to_binary(Value));
segment(Value) when is_atom(Value) -> segment(atom_to_binary(Value, 'utf8'));
segment(Value) when is_list(Value) -> segment(unicode:characters_to_binary(Value)).

-spec escape(byte()) -> binary().
escape(C) when C >= $a, C =< $z -> <<C>>;
escape(C) when C >= $A, C =< $Z -> <<C>>;
escape(C) when C >= $0, C =< $9 -> <<C>>;
escape($-) -> <<$->>;
escape($~) -> <<$~>>;
escape($_) -> <<$_>>;
escape($\s) -> <<$+>>;
escape(C) -> <<$%, (hex(C bsr 4)), (hex(C band 16#0F))>>.

-spec hex(0..15) -> byte().
hex(N) when N < 10 -> $0 + N;
hex(N) -> $A + N - 10.

%%%=============================================================================
%%% Publishers
%%%=============================================================================

%%------------------------------------------------------------------------------
%% @doc Put a caller in a shard's member queue.
%%
%% Straight to the queue through the default exchange, persistent, because
%% this message is the only durable record that somebody is waiting.
%% @end
%%------------------------------------------------------------------------------
-spec publish_member_call(non_neg_integer(), kz_term:api_terms()) -> 'ok'.
publish_member_call(Shard, Req) -> publish_member_call(Shard, Req, ?CONTENT_TYPE).

-spec publish_member_call(non_neg_integer(), kz_term:api_terms(), kz_term:ne_binary()) -> 'ok'.
publish_member_call(Shard, Req, ContentType) ->
    publish_to_queue(member_queue(Shard), Req, member_call_definition(), ContentType
                    ,[{'mandatory', 'true'}]
                    ).

%%------------------------------------------------------------------------------
%% @doc The `member_call' `publish_member_call/2' publishes, built and not
%% sent: `{BasicPublish, AmqpMsg}', for a publisher that sends it on a channel
%% of its own with `kz_amqp_channel:publish_on/3' --
%% `kazoo/amqp.publish_to_confirmed' finds it as `prepare_member_call'.
%% @end
%%------------------------------------------------------------------------------
-spec prepare_member_call(non_neg_integer() | kz_term:ne_binary(), kz_term:api_terms()) -> {tuple(), tuple()}.
prepare_member_call(Shard, Req) ->
    prepare_to_queue(member_queue(Shard), Req, member_call_definition(), ?CONTENT_TYPE
                    ,[{'mandatory', 'true'}]
                    ).

%%------------------------------------------------------------------------------
%% @doc Tell the shard that a caller has gone, on the same queue the caller
%% arrived on so that it is seen in order behind them.
%% @end
%%------------------------------------------------------------------------------
-spec publish_member_cancel(non_neg_integer(), kz_term:api_terms()) -> 'ok'.
publish_member_cancel(Shard, Req) -> publish_member_cancel(Shard, Req, ?CONTENT_TYPE).

-spec publish_member_cancel(non_neg_integer(), kz_term:api_terms(), kz_term:ne_binary()) -> 'ok'.
publish_member_cancel(Shard, Req, ContentType) ->
    publish_to_queue(member_queue(Shard), Req, member_cancel_definition(), ContentType, []).

-spec publish_member_offer(kz_term:api_terms()) -> 'ok'.
publish_member_offer(Req) -> publish_member_offer(Req, ?CONTENT_TYPE).

-spec publish_member_offer(kz_term:api_terms(), kz_term:ne_binary()) -> 'ok'.
publish_member_offer(Req, ContentType) ->
    RoutingKey = call_routing_key(account_id(Req), call_id(Req)),
    publish_to_exchange(RoutingKey, Req, member_offer_definition(), ContentType).

-spec publish_member_connected(kz_term:api_terms()) -> 'ok'.
publish_member_connected(Req) -> publish_member_connected(Req, ?CONTENT_TYPE).

-spec publish_member_connected(kz_term:api_terms(), kz_term:ne_binary()) -> 'ok'.
publish_member_connected(Req, ContentType) ->
    RoutingKey = call_routing_key(account_id(Req), call_id(Req)),
    publish_to_exchange(RoutingKey, Req, member_connected_definition(), ContentType).

-spec publish_member_result(kz_term:api_terms()) -> 'ok'.
publish_member_result(Req) -> publish_member_result(Req, ?CONTENT_TYPE).

-spec publish_member_result(kz_term:api_terms(), kz_term:ne_binary()) -> 'ok'.
publish_member_result(Req, ContentType) ->
    RoutingKey = call_routing_key(account_id(Req), call_id(Req)),
    publish_to_exchange(RoutingKey, Req, member_result_definition(), ContentType).

-spec publish_member_position(kz_term:api_terms()) -> 'ok'.
publish_member_position(Req) -> publish_member_position(Req, ?CONTENT_TYPE).

-spec publish_member_position(kz_term:api_terms(), kz_term:ne_binary()) -> 'ok'.
publish_member_position(Req, ContentType) ->
    RoutingKey = call_routing_key(account_id(Req), call_id(Req)),
    publish_to_exchange(RoutingKey, Req, member_position_definition(), ContentType).

%%------------------------------------------------------------------------------
%% @doc Hand a caller back to the callflow action at its Controller-Queue:
%% `pid://<cf_exe>/<queue>', as the other messages to the action go.
%% @end
%%------------------------------------------------------------------------------
-spec publish_member_continue(kz_term:ne_binary(), kz_term:api_terms()) -> 'ok'.
publish_member_continue(ControllerQ, Req) ->
    publish_member_continue(ControllerQ, Req, ?CONTENT_TYPE).

-spec publish_member_continue(kz_term:ne_binary(), kz_term:api_terms(), kz_term:ne_binary()) -> 'ok'.
publish_member_continue(ControllerQ, Req, ContentType) ->
    publish_targeted(ControllerQ, Req, member_continue_definition(), ContentType).

%%------------------------------------------------------------------------------
%% @doc The action's answer to a `member_continue', to the actor that sent
%% it: `pid://<actor>/<queue>', the node's call reply queue.
%% @end
%%------------------------------------------------------------------------------
-spec publish_member_continuing(kz_term:ne_binary(), kz_term:api_terms()) -> 'ok'.
publish_member_continuing(ReplyTo, Req) ->
    publish_member_continuing(ReplyTo, Req, ?CONTENT_TYPE).

-spec publish_member_continuing(kz_term:ne_binary(), kz_term:api_terms(), kz_term:ne_binary()) -> 'ok'.
publish_member_continuing(ReplyTo, Req, ContentType) ->
    publish_targeted(ReplyTo, Req, member_continuing_definition(), ContentType).

-spec publish_targeted(kz_term:ne_binary(), kz_term:api_terms(), kapi_definition:api(), kz_term:ne_binary()) -> 'ok'.
publish_targeted(Queue, Req, Definition, ContentType) ->
    {'ok', Payload} = kz_api:prepare_api_payload(Req
                                                ,kapi_definition:values(Definition)
                                                ,kapi_definition:build_fun(Definition)
                                                ),
    kz_amqp_util:targeted_publish(Queue, Payload, ContentType).

-spec publish_agent_availability(kz_term:api_terms()) -> 'ok'.
publish_agent_availability(Req) -> publish_agent_availability(Req, ?CONTENT_TYPE).

-spec publish_agent_availability(kz_term:api_terms(), kz_term:ne_binary()) -> 'ok'.
publish_agent_availability(Req, ContentType) ->
    RoutingKey = agent_routing_key(account_id(Req), agent_id(Req)),
    publish_to_exchange(RoutingKey, Req, agent_availability_definition(), ContentType).

-spec publish_agent_activity(kz_term:api_terms()) -> 'ok'.
publish_agent_activity(Req) -> publish_agent_activity(Req, ?CONTENT_TYPE).

-spec publish_agent_activity(kz_term:api_terms(), kz_term:ne_binary()) -> 'ok'.
publish_agent_activity(Req, ContentType) ->
    RoutingKey = agent_routing_key(account_id(Req), agent_id(Req)),
    publish_to_exchange(RoutingKey, Req, agent_activity_definition(), ContentType).

-spec publish_agent_offer(kz_term:api_terms()) -> 'ok'.
publish_agent_offer(Req) -> publish_agent_offer(Req, ?CONTENT_TYPE).

-spec publish_agent_offer(kz_term:api_terms(), kz_term:ne_binary()) -> 'ok'.
publish_agent_offer(Req, ContentType) ->
    RoutingKey = agent_routing_key(account_id(Req), agent_id(Req)),
    publish_to_exchange(RoutingKey, Req, agent_offer_definition(), ContentType).

-spec publish_agent_answered(kz_term:api_terms()) -> 'ok'.
publish_agent_answered(Req) -> publish_agent_answered(Req, ?CONTENT_TYPE).

-spec publish_agent_answered(kz_term:api_terms(), kz_term:ne_binary()) -> 'ok'.
publish_agent_answered(Req, ContentType) ->
    RoutingKey = agent_routing_key(account_id(Req), agent_id(Req)),
    publish_to_exchange(RoutingKey, Req, agent_answered_definition(), ContentType).

-spec publish_agent_wrapup(kz_term:api_terms()) -> 'ok'.
publish_agent_wrapup(Req) -> publish_agent_wrapup(Req, ?CONTENT_TYPE).

-spec publish_agent_wrapup(kz_term:api_terms(), kz_term:ne_binary()) -> 'ok'.
publish_agent_wrapup(Req, ContentType) ->
    RoutingKey = agent_routing_key(account_id(Req), agent_id(Req)),
    publish_to_exchange(RoutingKey, Req, agent_wrapup_definition(), ContentType).

-spec publish_queue_stats(kz_term:api_terms()) -> 'ok'.
publish_queue_stats(Req) -> publish_queue_stats(Req, ?CONTENT_TYPE).

-spec publish_queue_stats(kz_term:api_terms(), kz_term:ne_binary()) -> 'ok'.
publish_queue_stats(Req, ContentType) ->
    RoutingKey = queue_routing_key(account_id(Req), queue_id(Req)),
    publish_to_exchange(RoutingKey, Req, queue_stats_definition(), ContentType).

-spec publish_status_req(kz_term:api_terms()) -> 'ok'.
publish_status_req(Req) -> publish_status_req(Req, ?CONTENT_TYPE).

-spec publish_status_req(kz_term:api_terms(), kz_term:ne_binary()) -> 'ok'.
publish_status_req(Req, ContentType) ->
    RoutingKey = status_routing_key(account_id(Req)),
    publish_to_exchange(RoutingKey, Req, status_req_definition(), ContentType).

%%------------------------------------------------------------------------------
%% @doc Answer a status request, to the queue the requester asked from.
%%
%% `RespQ' is the request's `Server-ID'. See the module comment for why this
%% one does not go on the account's status key like the request did.
%% @end
%%------------------------------------------------------------------------------
-spec publish_status_resp(kz_term:ne_binary(), kz_term:api_terms()) -> 'ok'.
publish_status_resp(RespQ, Req) -> publish_status_resp(RespQ, Req, ?CONTENT_TYPE).

-spec publish_status_resp(kz_term:ne_binary(), kz_term:api_terms(), kz_term:ne_binary()) -> 'ok'.
publish_status_resp(RespQ, Req, ContentType) ->
    Definition = status_resp_definition(),
    {'ok', Payload} = kz_api:prepare_api_payload(Req
                                                ,kapi_definition:values(Definition)
                                                ,kapi_definition:build_fun(Definition)
                                                ),
    kz_amqp_util:targeted_publish(RespQ, Payload, ContentType).

-spec publish_pickup_req(kz_term:api_terms()) -> 'ok'.
publish_pickup_req(Req) -> publish_pickup_req(Req, ?CONTENT_TYPE).

-spec publish_pickup_req(kz_term:api_terms(), kz_term:ne_binary()) -> 'ok'.
publish_pickup_req(Req, ContentType) ->
    RoutingKey = pickup_routing_key(account_id(Req)),
    publish_to_exchange(RoutingKey, Req, pickup_req_definition(), ContentType).

%%------------------------------------------------------------------------------
%% @doc Answer a pickup request, to the queue the requester asked from, as a
%% status request is answered.
%% @end
%%------------------------------------------------------------------------------
-spec publish_pickup_resp(kz_term:ne_binary(), kz_term:api_terms()) -> 'ok'.
publish_pickup_resp(RespQ, Req) -> publish_pickup_resp(RespQ, Req, ?CONTENT_TYPE).

-spec publish_pickup_resp(kz_term:ne_binary(), kz_term:api_terms(), kz_term:ne_binary()) -> 'ok'.
publish_pickup_resp(RespQ, Req, ContentType) ->
    Definition = pickup_resp_definition(),
    {'ok', Payload} = kz_api:prepare_api_payload(Req
                                                ,kapi_definition:values(Definition)
                                                ,kapi_definition:build_fun(Definition)
                                                ),
    kz_amqp_util:targeted_publish(RespQ, Payload, ContentType).

-spec publish_to_exchange(kz_term:ne_binary(), kz_term:api_terms(), kapi_definition:api(), kz_term:ne_binary()) -> 'ok'.
publish_to_exchange(RoutingKey, Req, Definition, ContentType) ->
    {'ok', Payload} = kz_api:prepare_api_payload(Req
                                                ,kapi_definition:values(Definition)
                                                ,kapi_definition:build_fun(Definition)
                                                ),
    kz_amqp_util:basic_publish(?EXCHANGE, RoutingKey, Payload, ContentType).

%% A `member_call' is published `mandatory': the broker returns one whose
%% member queue does not exist instead of dropping it. Only a publisher that
%% listens for the return hears of it -- `kazoo/amqp.publish_to_confirmed' --
%% and anybody else loses nothing it had before.
-spec publish_to_queue(kz_term:ne_binary(), kz_term:api_terms(), kapi_definition:api(), kz_term:ne_binary(), kz_term:proplist()) -> 'ok'.
publish_to_queue(Queue, Req, Definition, ContentType, Props) ->
    {'ok', Payload} = kz_api:prepare_api_payload(Req
                                                ,kapi_definition:values(Definition)
                                                ,kapi_definition:build_fun(Definition)
                                                ),
    kz_amqp_util:basic_publish(?DEFAULT_EXCHANGE
                              ,Queue
                              ,Payload
                              ,ContentType
                              ,[{'delivery_mode', 2} | Props]
                              ).

%% What `publish_to_queue/5' publishes, built and not sent.
-spec prepare_to_queue(kz_term:ne_binary(), kz_term:api_terms(), kapi_definition:api(), kz_term:ne_binary(), kz_term:proplist()) ->
          {tuple(), tuple()}.
prepare_to_queue(Queue, Req, Definition, ContentType, Props) ->
    {'ok', Payload} = kz_api:prepare_api_payload(Req
                                                ,kapi_definition:values(Definition)
                                                ,kapi_definition:build_fun(Definition)
                                                ),
    kz_amqp_util:prepare_basic_publish(?DEFAULT_EXCHANGE
                                      ,Queue
                                      ,Payload
                                      ,ContentType
                                      ,[{'delivery_mode', 2} | Props]
                                      ).

%%%=============================================================================
%%% Bindings
%%%=============================================================================

%%------------------------------------------------------------------------------
%% @doc Bind a queue to the topic events.
%%
%% `restrict_to' names the families -- `call', `agent', `queue', `status' --
%% and `account_id', `call_id', `agent_id' and `queue_id' narrow one of them.
%% Anything left out is `*', so `[{restrict_to, [agent]}]' is every agent
%% event in every account and `[{restrict_to, [agent]}, {account_id, A}]' is
%% every agent event in one.
%%
%% `pickup' is a family too, and the only one left out when nothing is said:
%% its requests are for the node dispatching the account, which binds it by
%% name, and nobody watching the feed has any business with them.
%%
%% The member queues are not bound to anything: they are consumed
%% by name. See the module comment.
%% @end
%%------------------------------------------------------------------------------
-spec bind_q(kz_term:ne_binary(), kz_term:proplist()) -> 'ok'.
bind_q(Queue, Props) ->
    lists:foreach(fun(Key) ->
                          'ok' = kz_amqp_util:bind_q_to_exchange(Queue, Key, ?EXCHANGE)
                  end
                 ,binding_keys(Props)
                 ).

-spec unbind_q(kz_term:ne_binary(), kz_term:proplist()) -> 'ok'.
unbind_q(Queue, Props) ->
    lists:foreach(fun(Key) ->
                          _ = kz_amqp_util:unbind_q_from_exchange(Queue, Key, ?EXCHANGE)
                  end
                 ,binding_keys(Props)
                 ).

%%------------------------------------------------------------------------------
%% @doc The routing keys `bind_q/2' binds for these properties, one per
%% family, in the order `restrict_to' names them. Built by `routing_key/3'
%% like every published key, which is what a test of the two agreeing reads.
%% @end
%%------------------------------------------------------------------------------
-spec binding_keys(kz_term:proplist()) -> kz_term:ne_binaries().
binding_keys(Props) ->
    [binding_key(Restriction, Props) || Restriction <- restrictions(Props)].

%% Both spellings are accepted because the two callers spell it differently:
%% `gen_listener' bindings in Erlang are written as atoms, and the Gleam
%% listener builder hands over binaries.
-spec restrictions(kz_term:proplist()) -> [atom()].
restrictions(Props) ->
    [restriction(Restriction)
     || Restriction <- props:get_value('restrict_to', Props, ['call', 'agent', 'queue', 'status'])
    ].

-spec restriction(atom() | kz_term:ne_binary()) -> atom().
restriction(Restriction) when is_atom(Restriction) -> Restriction;
restriction(<<"call">>) -> 'call';
restriction(<<"agent">>) -> 'agent';
restriction(<<"queue">>) -> 'queue';
restriction(<<"status">>) -> 'status';
restriction(<<"pickup">>) -> 'pickup'.

-spec binding_key(atom(), kz_term:proplist()) -> kz_term:ne_binary().
binding_key('call', Props) ->
    call_routing_key(props:get_value('account_id', Props)
                    ,props:get_value('call_id', Props)
                    );
binding_key('agent', Props) ->
    agent_routing_key(props:get_value('account_id', Props)
                     ,props:get_value('agent_id', Props)
                     );
binding_key('queue', Props) ->
    queue_routing_key(props:get_value('account_id', Props)
                     ,props:get_value('queue_id', Props)
                     );
binding_key('status', Props) ->
    status_routing_key(props:get_value('account_id', Props));
binding_key('pickup', Props) ->
    pickup_routing_key(props:get_value('account_id', Props)).

%%------------------------------------------------------------------------------
%% @doc Declare the exchange this API publishes its events on.
%%
%% Durable: a broker restart must not leave the bindings pointing at nothing.
%% @end
%%------------------------------------------------------------------------------
-spec declare_exchanges() -> 'ok'.
declare_exchanges() ->
    kz_amqp_util:new_exchange(?EXCHANGE, ?EXCHANGE_TYPE, [{'durable', 'true'}]).

%%%=============================================================================
%%% Readers
%%%=============================================================================

-spec account_id(kz_term:api_terms()) -> kz_term:api_ne_binary().
account_id(Props) when is_list(Props) -> props:get_value(?KEY_ACCOUNT_ID, Props);
account_id(JObj) -> kz_json:get_ne_binary_value(?KEY_ACCOUNT_ID, JObj).

-spec queue_id(kz_term:api_terms()) -> kz_term:api_ne_binary().
queue_id(Props) when is_list(Props) -> props:get_value(?KEY_QUEUE_ID, Props);
queue_id(JObj) -> kz_json:get_ne_binary_value(?KEY_QUEUE_ID, JObj).

-spec agent_id(kz_term:api_terms()) -> kz_term:api_ne_binary().
agent_id(Props) when is_list(Props) -> props:get_value(?KEY_AGENT_ID, Props);
agent_id(JObj) -> kz_json:get_ne_binary_value(?KEY_AGENT_ID, JObj).

-spec call_id(kz_term:api_terms()) -> kz_term:api_ne_binary().
call_id(Props) when is_list(Props) -> props:get_value(?KEY_CALL_ID, Props);
call_id(JObj) -> kz_json:get_ne_binary_value(?KEY_CALL_ID, JObj).

