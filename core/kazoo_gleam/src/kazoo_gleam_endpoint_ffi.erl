%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2026, Vonix LLC
%%% @doc The Erlang side of `kazoo/endpoints': what a bridge can be pointed at.
%%%
%%% This Source Code Form is subject to the terms of the Mozilla Public
%%% License, v. 2.0. If a copy of the MPL was not distributed with this
%%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%%
%%% `kz_endpoint:build/2,3' answers one endpoint object per device that will
%%% actually ring, having applied call forwarding, do-not-disturb, the
%%% hotdesk, the device's own settings and -- because the call carries the
%%% `Queue-ID' channel variable -- the exclusion of devices that opted out of
%%% queue calls. The objects cross to Gleam as plain maps.
%%% @end
%%%-----------------------------------------------------------------------------
-module(kazoo_gleam_endpoint_ffi).

-export([build/2
        ,build_with/3
        ,by_owner/2
        ,owned_by/3
        ]).

%% @doc Every endpoint `Id' rings. A device id gives one, a user id gives one
%% per device that user owns.
-spec build(any(), binary()) -> {'ok', [map()]} | {'error', binary()}.
build(Call, Id) ->
    endpoints(fun() -> kz_endpoint:build(Id, Call) end).

%% @doc The same, with the properties that override what the endpoint asks
%% for: `can_call_self', `suppress_clid', `source', the codecs.
-spec build_with(any(), binary(), binary()) -> {'ok', [map()]} | {'error', binary()}.
build_with(Call, Id, PropertiesJson) ->
    endpoints(fun() ->
                      kz_endpoint:build(Id, kz_json:from_map(decode_map(PropertiesJson)), Call)
              end).

%% @doc Every endpoint owned by a user, which is `build/2' on a user id with
%% the failures of individual devices dropped rather than fatal.
-spec by_owner(any(), binary()) -> {'ok', [map()]} | {'error', binary()}.
by_owner(Call, OwnerId) ->
    case loaded('kz_endpoints') of
        'false' -> {'error', <<"unavailable">>};
        'true' ->
            try kz_endpoints:by_owner_id(OwnerId, Call) of
                {'error', Reason} -> {'error', reason(Reason)};
                Endpoints when is_list(Endpoints) ->
                    {'ok', [kz_json:to_map(Endpoint) || Endpoint <- Endpoints]}
            catch
                _E:_R -> {'error', <<"unavailable">>}
            end
    end.

%% @doc The ids of everything of one kind a user owns: `device', `vmbox',
%% `callflow'. Unlike `build', this reads the account database directly and
%% takes no call.
-spec owned_by(binary(), binary(), binary()) -> [binary()].
owned_by(AccountDb, OwnerId, Kind) ->
    case loaded('kz_attributes') of
        'false' -> [];
        'true' ->
            try kz_attributes:owned_by(OwnerId, Kind, AccountDb) of
                Ids when is_list(Ids) -> Ids;
                _Other -> []
            catch
                _E:_R -> []
            end
    end.

%%%=============================================================================
%%% Internal
%%%=============================================================================

-spec endpoints(fun(() -> any())) -> {'ok', [map()]} | {'error', binary()}.
endpoints(Fun) ->
    case loaded('kz_endpoint') of
        'false' -> {'error', <<"unavailable">>};
        'true' ->
            try Fun() of
                {'ok', Endpoints} ->
                    {'ok', [kz_json:to_map(Endpoint) || Endpoint <- Endpoints]};
                {'error', Reason} -> {'error', reason(Reason)}
            catch
                _E:_R -> {'error', <<"unavailable">>}
            end
    end.

-spec loaded(atom()) -> boolean().
loaded(Module) ->
    case code:ensure_loaded(Module) of
        {'module', Module} -> 'true';
        {'error', _Reason} -> 'false'
    end.

-spec decode_map(binary()) -> map().
decode_map(Json) ->
    case json:decode(Json) of
        Map when is_map(Map) -> Map;
        _Other -> #{}
    end.

-spec reason(any()) -> binary().
reason(Reason) when is_atom(Reason) -> atom_to_binary(Reason, 'utf8');
reason(Reason) when is_binary(Reason) -> Reason;
reason(Reason) -> iolist_to_binary(io_lib:format("~p", [Reason])).
