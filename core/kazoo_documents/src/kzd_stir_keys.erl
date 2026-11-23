%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2010-2026, 2600Hz
%%% @doc Accessors for `stir_keys' document.
%%% @end
%%%-----------------------------------------------------------------------------
-module(kzd_stir_keys).

-export([new/0]).
-export([organization/1, organization/2, set_organization/2]).
-export([scope/1, scope/2, set_scope/2]).
-export([spc/1, spc/2, set_spc/2]).


-include("kz_documents.hrl").

-type doc() :: kz_json:object().
-export_type([doc/0]).

-define(SCHEMA, <<"stir_keys">>).

-spec new() -> doc().
new() ->
    kz_json_schema:default_object(?SCHEMA).

-spec organization(doc()) -> kz_term:api_ne_binary().
organization(Doc) ->
    organization(Doc, 'undefined').

-spec organization(doc(), Default) -> kz_term:ne_binary() | Default.
organization(Doc, Default) ->
    kz_json:get_ne_binary_value([<<"organization">>], Doc, Default).

-spec set_organization(doc(), kz_term:ne_binary()) -> doc().
set_organization(Doc, Organization) ->
    kz_json:set_value([<<"organization">>], Organization, Doc).

-spec scope(doc()) -> binary().
scope(Doc) ->
    scope(Doc, <<"system">>).

-spec scope(doc(), Default) -> binary() | Default.
scope(Doc, Default) ->
    kz_json:get_binary_value([<<"scope">>], Doc, Default).

-spec set_scope(doc(), binary()) -> doc().
set_scope(Doc, Scope) ->
    kz_json:set_value([<<"scope">>], Scope, Doc).

-spec spc(doc()) -> kz_term:api_ne_binary().
spc(Doc) ->
    spc(Doc, 'undefined').

-spec spc(doc(), Default) -> kz_term:ne_binary() | Default.
spc(Doc, Default) ->
    kz_json:get_ne_binary_value([<<"spc">>], Doc, Default).

-spec set_spc(doc(), kz_term:ne_binary()) -> doc().
set_spc(Doc, Spc) ->
    kz_json:set_value([<<"spc">>], Spc, Doc).
