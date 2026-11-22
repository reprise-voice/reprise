%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2013-2023, 2600Hz
%%% @doc
%%% @author James Aimonetti
%%%
%%% This Source Code Form is subject to the terms of the Mozilla Public
%%% License, v. 2.0. If a copy of the MPL was not distributed with this
%%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%%
%%% @end
%%%-----------------------------------------------------------------------------
-module(ecallmgr_channel_redirect).

-export([redirect/2
        ,redirect_remote/2
        ]).

-include("ecallmgr.hrl").

-spec redirect(kz_term:ne_binary(), atom() | kz_term:ne_binary()) -> ecallmgr_util:send_cmd_ret().
redirect(UUID, DestinationNode) ->
    URL = ecallmgr_fs_node:sip_url(DestinationNode),
    case kapps_config:get_boolean(?APP_NAME, <<"redirect_via_proxy">>, 'true') of
        'true' -> redirect_via_proxy(URL, UUID);
        'false' -> redirect_via_endpoint(URL, UUID)
    end.

-spec redirect_remote(kz_term:ne_binary(), kz_json:object()) -> ecallmgr_util:send_cmd_ret().
redirect_remote(UUID, ChannelStatusJObj) ->
    URL = kz_json:get_value(<<"Switch-URL">>, ChannelStatusJObj),

    case kapps_config:get_boolean(?APP_NAME, <<"redirect_via_proxy">>, 'true') of
        'true' -> redirect_via_proxy(URL, UUID);
        'false' -> redirect_via_endpoint(URL, UUID)
    end.

-spec redirect_via_proxy(kz_term:ne_binary(), kz_term:ne_binary()) -> ecallmgr_util:send_cmd_ret().
redirect_via_proxy(DestNodeURL, UUID) ->
    {'ok', #channel{destination=ToUser
                   ,realm=Realm
                   }=Channel
    } = ecallmgr_fs_channel:fetch(UUID, 'record'),
    Contact = <<"sip:", ToUser/binary, "@", Realm/binary>>,

    RedirectURL = binary:replace(DestNodeURL, <<"mod_sofia@">>, <<>>),
    send_redirect(RedirectURL, Contact, Channel).

-spec redirect_via_endpoint(kz_term:ne_binary(), kz_term:ne_binary()) -> ecallmgr_util:send_cmd_ret().
redirect_via_endpoint(DestNodeURL, UUID) ->
    {'ok', #channel{destination=ToUser}=Channel} = ecallmgr_fs_channel:fetch(UUID, 'record'),
    Contact = binary:replace(DestNodeURL, <<"mod_sofia">>, ToUser),
    send_redirect('undefined', Contact, Channel).

-spec send_redirect(kz_term:api_binary(), kz_term:ne_binary(), channel()) ->
          ecallmgr_util:send_cmd_ret().
send_redirect(RedirectUrl, Contact, #channel{node=Node
                                            ,uuid=UUID
                                            ,answered=IsAnswered
                                            }) ->
    _ = ecallmgr_fs_command:set(Node, UUID, redirect_vars(RedirectUrl, Contact, IsAnswered)),
    ecallmgr_util:send_cmd(Node, UUID, redirect_app(IsAnswered), Contact).

%% @doc The variables to set on the channel before the redirect.
%%
%% An unanswered channel is sent a 302 and hangs up, and the same Call-ID
%% then arrives at the destination as a new channel, which is the one that
%% reports the call. This channel is marked with `Redirected-To' so that
%% mod_reprise fires no CDR report for it, a zero-second stub that would
%% be filed under the same Call-ID; the media server checks the answer
%% state itself when the channel reports, so a channel that answered before
%% the redirect could execute, and stayed, keeps its record. The marker is
%% not `process_cdr=false': FreeSWITCH honours that before any reporting
%% hook runs and could not re-check the answer. An answered channel is
%% deflected with a REFER instead: the endpoint's new call has its own
%% Call-ID and this channel's record stands, so it is not marked.
%% @end
-spec redirect_vars(kz_term:api_binary(), kz_term:ne_binary(), boolean()) -> kz_term:proplist().
redirect_vars(RedirectUrl, Contact, IsAnswered) ->
    props:filter_undefined(
      [{redirect_server_header(IsAnswered), RedirectUrl}
      ,{?REDIRECTED_TO_CCV, redirected_to(RedirectUrl, Contact, IsAnswered)}
      ]).

-spec redirected_to(kz_term:api_binary(), kz_term:ne_binary(), boolean()) -> kz_term:api_binary().
redirected_to(_RedirectUrl, _Contact, 'true') -> 'undefined';
redirected_to('undefined', Contact, 'false') -> Contact;
redirected_to(RedirectUrl, _Contact, 'false') -> RedirectUrl.

-spec redirect_app(boolean()) -> kz_term:ne_binary().
redirect_app('true') -> <<"deflect">>;
redirect_app('false') -> <<"redirect">>.

-spec redirect_server_header(boolean()) -> kz_term:ne_binary().
redirect_server_header('true') -> <<"sip_h_X-Redirect-Server">>;
redirect_server_header('false') -> <<"sip_rh_X-Redirect-Server">>.
