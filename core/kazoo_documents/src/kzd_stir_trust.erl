%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2010-2026, 2600Hz
%%% @doc Accessors for `stir_trust' document.
%%% @end
%%%-----------------------------------------------------------------------------
-module(kzd_stir_trust).

-export([new/0]).
-export([action/1, action/2, set_action/2]).
-export([kind/1, kind/2, set_kind/2]).
-export([pem/1, pem/2, set_pem/2]).
-export([role/1, role/2, set_role/2]).


-include("kz_documents.hrl").

-type doc() :: kz_json:object().
-export_type([doc/0]).

-define(SCHEMA, <<"stir_trust">>).

-spec new() -> doc().
new() ->
    kz_json_schema:default_object(?SCHEMA).

-spec action(doc()) -> kz_term:api_binary().
action(Doc) ->
    action(Doc, 'undefined').

-spec action(doc(), Default) -> binary() | Default.
action(Doc, Default) ->
    kz_json:get_binary_value([<<"action">>], Doc, Default).

-spec set_action(doc(), binary()) -> doc().
set_action(Doc, Action) ->
    kz_json:set_value([<<"action">>], Action, Doc).

-spec kind(doc()) -> kz_term:api_binary().
kind(Doc) ->
    kind(Doc, 'undefined').

-spec kind(doc(), Default) -> binary() | Default.
kind(Doc, Default) ->
    kz_json:get_binary_value([<<"kind">>], Doc, Default).

-spec set_kind(doc(), binary()) -> doc().
set_kind(Doc, Kind) ->
    kz_json:set_value([<<"kind">>], Kind, Doc).

-spec pem(doc()) -> kz_term:api_ne_binary().
pem(Doc) ->
    pem(Doc, 'undefined').

-spec pem(doc(), Default) -> kz_term:ne_binary() | Default.
pem(Doc, Default) ->
    kz_json:get_ne_binary_value([<<"pem">>], Doc, Default).

-spec set_pem(doc(), kz_term:ne_binary()) -> doc().
set_pem(Doc, Pem) ->
    kz_json:set_value([<<"pem">>], Pem, Doc).

-spec role(doc()) -> kz_term:api_binary().
role(Doc) ->
    role(Doc, 'undefined').

-spec role(doc(), Default) -> binary() | Default.
role(Doc, Default) ->
    kz_json:get_binary_value([<<"role">>], Doc, Default).

-spec set_role(doc(), binary()) -> doc().
set_role(Doc, Role) ->
    kz_json:set_value([<<"role">>], Role, Doc).
