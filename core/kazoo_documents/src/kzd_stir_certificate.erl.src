%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2010-2026, 2600Hz
%%% @doc Accessors for `stir_certificate' document.
%%% @end
%%%-----------------------------------------------------------------------------
-module(kzd_stir_certificate).

-export([new/0]).
-export([certificate/1, certificate/2, set_certificate/2]).


-include("kz_documents.hrl").

-type doc() :: kz_json:object().
-export_type([doc/0]).

-define(SCHEMA, <<"stir_certificate">>).

-spec new() -> doc().
new() ->
    kz_json_schema:default_object(?SCHEMA).

-spec certificate(doc()) -> kz_term:api_ne_binary().
certificate(Doc) ->
    certificate(Doc, 'undefined').

-spec certificate(doc(), Default) -> kz_term:ne_binary() | Default.
certificate(Doc, Default) ->
    kz_json:get_ne_binary_value([<<"certificate">>], Doc, Default).

-spec set_certificate(doc(), kz_term:ne_binary()) -> doc().
set_certificate(Doc, Certificate) ->
    kz_json:set_value([<<"certificate">>], Certificate, Doc).
