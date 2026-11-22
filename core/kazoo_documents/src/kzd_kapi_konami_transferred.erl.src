%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2010-2026, 2600Hz
%%% @doc Accessors for `kapi_konami_transferred' document.
%%% @end
%%%-----------------------------------------------------------------------------
-module(kzd_kapi_konami_transferred).

-export([new/0]).
-export([call/1, call/2, set_call/2]).
-export([event_category/1, event_category/2, set_event_category/2]).
-export([event_name/1, event_name/2, set_event_name/2]).
-export([target/1, target/2, set_target/2]).
-export([transferee/1, transferee/2, set_transferee/2]).
-export([transferor/1, transferor/2, set_transferor/2]).


-include("kz_documents.hrl").

-type doc() :: kz_json:object().
-export_type([doc/0]).

-define(SCHEMA, <<"kapi.konami.transferred">>).

-spec new() -> doc().
new() ->
    kz_json_schema:default_object(?SCHEMA).

-spec call(doc()) -> kz_term:api_object().
call(Doc) ->
    call(Doc, 'undefined').

-spec call(doc(), Default) -> kz_json:object() | Default.
call(Doc, Default) ->
    kz_json:get_json_value([<<"Call">>], Doc, Default).

-spec set_call(doc(), kz_json:object()) -> doc().
set_call(Doc, Call) ->
    kz_json:set_value([<<"Call">>], Call, Doc).

-spec event_category(doc()) -> any().
event_category(Doc) ->
    event_category(Doc, 'undefined').

-spec event_category(doc(), Default) -> any() | Default.
event_category(Doc, Default) ->
    kz_json:get_value([<<"Event_Category">>], Doc, Default).

-spec set_event_category(doc(), any()) -> doc().
set_event_category(Doc, EventCategory) ->
    kz_json:set_value([<<"Event_Category">>], EventCategory, Doc).

-spec event_name(doc()) -> any().
event_name(Doc) ->
    event_name(Doc, 'undefined').

-spec event_name(doc(), Default) -> any() | Default.
event_name(Doc, Default) ->
    kz_json:get_value([<<"Event_Name">>], Doc, Default).

-spec set_event_name(doc(), any()) -> doc().
set_event_name(Doc, EventName) ->
    kz_json:set_value([<<"Event_Name">>], EventName, Doc).

-spec target(doc()) -> kz_term:api_binary().
target(Doc) ->
    target(Doc, 'undefined').

-spec target(doc(), Default) -> binary() | Default.
target(Doc, Default) ->
    kz_json:get_binary_value([<<"Target">>], Doc, Default).

-spec set_target(doc(), binary()) -> doc().
set_target(Doc, Target) ->
    kz_json:set_value([<<"Target">>], Target, Doc).

-spec transferee(doc()) -> kz_term:api_binary().
transferee(Doc) ->
    transferee(Doc, 'undefined').

-spec transferee(doc(), Default) -> binary() | Default.
transferee(Doc, Default) ->
    kz_json:get_binary_value([<<"Transferee">>], Doc, Default).

-spec set_transferee(doc(), binary()) -> doc().
set_transferee(Doc, Transferee) ->
    kz_json:set_value([<<"Transferee">>], Transferee, Doc).

-spec transferor(doc()) -> kz_term:api_binary().
transferor(Doc) ->
    transferor(Doc, 'undefined').

-spec transferor(doc(), Default) -> binary() | Default.
transferor(Doc, Default) ->
    kz_json:get_binary_value([<<"Transferor">>], Doc, Default).

-spec set_transferor(doc(), binary()) -> doc().
set_transferor(Doc, Transferor) ->
    kz_json:set_value([<<"Transferor">>], Transferor, Doc).
