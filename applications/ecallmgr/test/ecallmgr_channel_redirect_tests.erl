%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2026, Vonix LLC
%%% @doc A channel sent to another media server keeps its Call-ID, so the
%%% channel that arrives there reports the call. Before an unanswered channel
%%% is redirected it is marked with `Redirected-To', which is what lets
%%% ecallmgr_cdr_event_publisher drop the bounce's zero-second report. An
%%% answered channel is deflected instead and its record stands, so it is
%%% not marked.
%%%
%%% This Source Code Form is subject to the terms of the Mozilla Public
%%% License, v. 2.0. If a copy of the MPL was not distributed with this
%%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%%
%%% @end
%%%-----------------------------------------------------------------------------
-module(ecallmgr_channel_redirect_tests).

-include_lib("eunit/include/eunit.hrl").
-include("../src/ecallmgr.hrl").

-define(UUID, <<"e2e-park-direct-retrieve">>).
-define(NODE, 'freeswitch@fs-1.example.invalid').
-define(OTHER_NODE, 'freeswitch@fs-2.example.invalid').
-define(OTHER_URL, <<"sip:mod_sofia@10.0.0.2:11000">>).
-define(OTHER_PROXY_URL, <<"sip:10.0.0.2:11000">>).
-define(TO_USER, <<"*32701">>).
-define(REALM, <<"xfer.example.invalid">>).

redirect_test_() ->
    {'foreach'
    ,fun setup/0
    ,fun cleanup/1
    ,[fun unanswered_via_proxy_is_marked/1
     ,fun answered_via_proxy_is_deflected_unmarked/1
     ,fun unanswered_via_endpoint_is_marked/1
     ,fun answered_via_endpoint_sets_nothing/1
     ,fun remote_redirect_uses_the_switch_url/1
     ]
    }.

setup() ->
    Mods = ['ecallmgr_fs_channel', 'ecallmgr_fs_node', 'ecallmgr_fs_command', 'ecallmgr_util', 'kapps_config'],
    lists:foreach(fun(M) -> meck:new(M, ['passthrough', 'non_strict']) end, Mods),
    meck:expect('ecallmgr_fs_node', 'sip_url', fun(?OTHER_NODE) -> ?OTHER_URL end),
    meck:expect('ecallmgr_fs_command', 'set', fun(_Node, _UUID, _Props) -> 'ok' end),
    meck:expect('ecallmgr_util', 'send_cmd', fun(_Node, _UUID, _App, _Args) -> 'ok' end),
    Mods.

cleanup(Mods) ->
    meck:unload(Mods).

channel(IsAnswered) ->
    meck:expect('ecallmgr_fs_channel', 'fetch'
               ,fun(?UUID, 'record') ->
                        {'ok', #channel{uuid=?UUID
                                       ,node=?NODE
                                       ,destination=?TO_USER
                                       ,realm=?REALM
                                       ,answered=IsAnswered
                                       }}
                end
               ).

via_proxy(ViaProxy) ->
    meck:expect('kapps_config', 'get_boolean'
               ,fun(<<"ecallmgr">>, <<"redirect_via_proxy">>, 'true') -> ViaProxy end
               ).

%% The variables set on the channel and the application sent to it.
set_vars() ->
    [Props || {_Pid, {'ecallmgr_fs_command', 'set', [?NODE, ?UUID, Props]}, _Ret}
                  <- meck:history('ecallmgr_fs_command')].

sent_app() ->
    [{App, Args} || {_Pid, {'ecallmgr_util', 'send_cmd', [?NODE, ?UUID, App, Args]}, _Ret}
                        <- meck:history('ecallmgr_util')].

unanswered_via_proxy_is_marked(_) ->
    {"an unanswered channel redirected through the proxy is marked with the destination"
    ,?_test(begin
                channel('false'),
                via_proxy('true'),
                'ok' = ecallmgr_channel_redirect:redirect(?UUID, ?OTHER_NODE),
                ?assertEqual([[{<<"sip_rh_X-Redirect-Server">>, ?OTHER_PROXY_URL}
                              ,{?REDIRECTED_TO_CCV, ?OTHER_PROXY_URL}
                              ]]
                            ,set_vars()
                            ),
                ?assertEqual([{<<"redirect">>, <<"sip:", ?TO_USER/binary, "@", ?REALM/binary>>}], sent_app())
            end)
    }.

answered_via_proxy_is_deflected_unmarked(_) ->
    {"an answered channel is deflected and keeps its record"
    ,?_test(begin
                channel('true'),
                via_proxy('true'),
                'ok' = ecallmgr_channel_redirect:redirect(?UUID, ?OTHER_NODE),
                ?assertEqual([[{<<"sip_h_X-Redirect-Server">>, ?OTHER_PROXY_URL}]], set_vars()),
                ?assertEqual([{<<"deflect">>, <<"sip:", ?TO_USER/binary, "@", ?REALM/binary>>}], sent_app())
            end)
    }.

unanswered_via_endpoint_is_marked(_) ->
    {"an unanswered channel redirected straight at the media server is marked with the contact"
    ,?_test(begin
                channel('false'),
                via_proxy('false'),
                Contact = <<"sip:", ?TO_USER/binary, "@10.0.0.2:11000">>,
                'ok' = ecallmgr_channel_redirect:redirect(?UUID, ?OTHER_NODE),
                ?assertEqual([[{?REDIRECTED_TO_CCV, Contact}]], set_vars()),
                ?assertEqual([{<<"redirect">>, Contact}], sent_app())
            end)
    }.

answered_via_endpoint_sets_nothing(_) ->
    {"an answered channel redirected straight at the media server sets no variable"
    ,?_test(begin
                channel('true'),
                via_proxy('false'),
                'ok' = ecallmgr_channel_redirect:redirect(?UUID, ?OTHER_NODE),
                ?assertEqual([[]], set_vars()),
                ?assertMatch([{<<"deflect">>, _}], sent_app())
            end)
    }.

remote_redirect_uses_the_switch_url(_) ->
    {"a redirect to a media server known only by its channel status is marked the same way"
    ,?_test(begin
                channel('false'),
                via_proxy('true'),
                Status = kz_json:from_list([{<<"Switch-URL">>, ?OTHER_URL}]),
                'ok' = ecallmgr_channel_redirect:redirect_remote(?UUID, Status),
                ?assertEqual([[{<<"sip_rh_X-Redirect-Server">>, ?OTHER_PROXY_URL}
                              ,{?REDIRECTED_TO_CCV, ?OTHER_PROXY_URL}
                              ]]
                            ,set_vars()
                            ),
                ?assertMatch([{<<"redirect">>, _}], sent_app())
            end)
    }.
