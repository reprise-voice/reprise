%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2010-2026, 2600Hz
%%% @doc Accessors for `stir_key_status' document.
%%% @end
%%%-----------------------------------------------------------------------------
-module(kzd_stir_key_status).

-export([new/0]).
-export([status/1, status/2, set_status/2]).


-include("kz_documents.hrl").

-type doc() :: kz_json:object().
-export_type([doc/0]).

-define(SCHEMA, <<"stir_key_status">>).

-spec new() -> doc().
new() ->
    kz_json_schema:default_object(?SCHEMA).

-spec status(doc()) -> kz_term:api_binary().
status(Doc) ->
    status(Doc, 'undefined').

-spec status(doc(), Default) -> binary() | Default.
status(Doc, Default) ->
    kz_json:get_binary_value([<<"status">>], Doc, Default).

-spec set_status(doc(), binary()) -> doc().
set_status(Doc, Status) ->
    kz_json:set_value([<<"status">>], Status, Doc).
