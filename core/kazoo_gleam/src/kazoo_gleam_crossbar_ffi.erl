%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2026, Vonix LLC
%%% @doc The Erlang side of `kazoo/crossbar': the request context, the
%%% document helpers, and the schema validator.
%%%
%%% This Source Code Form is subject to the terms of the Mozilla Public
%%% License, v. 2.0. If a copy of the MPL was not distributed with this
%%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%%
%%% `cb_context:context()' is a record, so it crosses opaque exactly as
%%% `kapps_call' does and every read of it happens here.
%%%
%%% Outside a release there is no `cb_context' either, and a context is
%%% instead the map `?FAKE(Map)', which the accessors and setters read and
%%% write in the same shape. That is what lets a Gleam Crossbar module's own
%%% decisions be tested without a node.
%%%
%%% What binds a Gleam module to Crossbar is `kazoo_gleam_cb'.
%%% @end
%%%-----------------------------------------------------------------------------
-module(kazoo_gleam_crossbar_ffi).

-export([new/0
        ,is_context/1
        ,req_data/1
        ,set_req_data/2
        ,req_verb/1
        ,req_nouns/1
        ,req_value/2
        ,req_param/2
        ,query_string/1
        ,account_id/1
        ,db_name/1
        ,account_modb/1
        ,auth_account_id/1
        ,auth_user_id/1
        ,is_account_admin/1
        ,is_superduper_admin/1
        ,doc/1
        ,set_doc/2
        ,resp_data/1
        ,set_resp_data/2
        ,resp_status/1
        ,set_resp_status/2
        ,set_content_types_provided/2
        ,set_resp_body/3
        ,resp_body/1
        ,store/3
        ,fetch/2
        ,add_validation_error/4
        ,add_system_error/2
        ,add_error/4
        ,validate_request_data/3
        ,load_doc/3
        ,save_doc/1
        ,delete_doc/1
        ,load_merge/3
        ,patch_and_validate/3
        ,load_view/3
        ,start_module/1
        ]).

%% A context outside a release: the handful of fields a module reads and
%% writes, and nothing else.
-define(FAKE(Map), {'kazoo_gleam_context', Map}).

-type context() :: any().
-export_type([context/0]).

%%%=============================================================================
%%% The context
%%%=============================================================================

-spec new() -> context().
new() ->
    case loaded('cb_context') of
        'false' -> ?FAKE(#{});
        'true' -> cb_context:new()
    end.

-spec is_context(context()) -> boolean().
is_context(?FAKE(_Map)) -> 'true';
is_context(Context) ->
    loaded('cb_context')
        andalso cb_context:is_context(Context).

%% @doc The request body, already checked against the envelope schema and
%% unwrapped from `data'.
-spec req_data(context()) -> map().
req_data(?FAKE(Map)) -> maps:get(<<"req_data">>, Map, #{});
req_data(Context) -> as_map(read(Context, 'req_data', #{})).

-spec set_req_data(context(), binary()) -> context().
set_req_data(?FAKE(Map), Json) ->
    ?FAKE(Map#{<<"req_data">> => decode_map(Json)});
set_req_data(Context, Json) ->
    write(Context, 'set_req_data', decode(Json)).

%% @doc `GET', `PUT', `POST', `PATCH' or `DELETE'.
-spec req_verb(context()) -> binary().
req_verb(?FAKE(Map)) -> maps:get(<<"req_verb">>, Map, <<"GET">>);
req_verb(Context) -> read(Context, 'req_verb', <<"GET">>).

%% @doc The path as Crossbar parsed it, deepest noun first:
%% `/accounts/{id}/queues/{qid}' is `[{queues,[qid]}, {accounts,[id]}]'.
-spec req_nouns(context()) -> [{binary(), [binary()]}].
req_nouns(?FAKE(Map)) -> maps:get(<<"req_nouns">>, Map, []);
req_nouns(Context) ->
    case read(Context, 'req_nouns', []) of
        Nouns when is_list(Nouns) -> Nouns;
        _Other -> []
    end.

%% @doc A value from the request body, then the query string, then the
%% envelope, which is the order Crossbar looks in.
-spec req_value(context(), [binary()]) -> {'ok', any()} | {'error', 'nil'}.
req_value(?FAKE(Map), Path) ->
    at_path(maps:get(<<"req_data">>, Map, #{}), Path);
req_value(Context, Path) ->
    case loaded('cb_context') of
        'false' -> {'error', 'nil'};
        'true' ->
            try cb_context:req_value(Context, Path) of
                Value -> defined(to_map_value(Value))
            catch
                _E:_R -> {'error', 'nil'}
            end
    end.

%% @doc A query string parameter.
-spec req_param(context(), binary()) -> {'ok', any()} | {'error', 'nil'}.
req_param(?FAKE(Map), Key) ->
    at_path(maps:get(<<"query_string">>, Map, #{}), [Key]);
req_param(Context, Key) ->
    case loaded('cb_context') of
        'false' -> {'error', 'nil'};
        'true' ->
            try cb_context:req_param(Context, Key) of
                Value -> defined(to_map_value(Value))
            catch
                _E:_R -> {'error', 'nil'}
            end
    end.

-spec query_string(context()) -> map().
query_string(?FAKE(Map)) -> maps:get(<<"query_string">>, Map, #{});
query_string(Context) -> as_map(read(Context, 'query_string', #{})).

%% @doc The account the request is against, which is not the account the
%% token belongs to.
-spec account_id(context()) -> {'ok', binary()} | {'error', 'nil'}.
account_id(?FAKE(Map)) -> present(maps:get(<<"account_id">>, Map, 'undefined'));
account_id(Context) -> present(read(Context, 'account_id', 'undefined')).

%% @doc The database this request reads and writes, which is the account's
%% own unless the module set another.
-spec db_name(context()) -> {'ok', binary()} | {'error', 'nil'}.
db_name(?FAKE(Map)) -> present(maps:get(<<"db_name">>, Map, 'undefined'));
db_name(Context) -> present(read(Context, 'db_name', 'undefined')).

%% @doc This month's database for the account the request is against.
-spec account_modb(context()) -> {'ok', binary()} | {'error', 'nil'}.
account_modb(?FAKE(Map)) -> present(maps:get(<<"account_modb">>, Map, 'undefined'));
account_modb(Context) -> present(read(Context, 'account_modb', 'undefined')).

%% @doc The account the token belongs to.
-spec auth_account_id(context()) -> {'ok', binary()} | {'error', 'nil'}.
auth_account_id(?FAKE(Map)) ->
    present(maps:get(<<"auth_account_id">>, Map, 'undefined'));
auth_account_id(Context) -> present(read(Context, 'auth_account_id', 'undefined')).

-spec auth_user_id(context()) -> {'ok', binary()} | {'error', 'nil'}.
auth_user_id(?FAKE(Map)) -> present(maps:get(<<"auth_user_id">>, Map, 'undefined'));
auth_user_id(Context) -> present(read(Context, 'auth_user_id', 'undefined')).

-spec is_account_admin(context()) -> boolean().
is_account_admin(?FAKE(Map)) -> maps:get(<<"is_account_admin">>, Map, 'false');
is_account_admin(Context) -> read(Context, 'is_account_admin', 'false') =:= 'true'.

-spec is_superduper_admin(context()) -> boolean().
is_superduper_admin(?FAKE(Map)) -> maps:get(<<"is_superduper_admin">>, Map, 'false');
is_superduper_admin(Context) -> read(Context, 'is_superduper_admin', 'false') =:= 'true'.

%% @doc The document the request is about: loaded by `load_doc', or built by
%% the validator out of the request body.
-spec doc(context()) -> map().
doc(?FAKE(Map)) -> maps:get(<<"doc">>, Map, #{});
doc(Context) -> as_map(read(Context, 'doc', #{})).

-spec set_doc(context(), binary()) -> context().
set_doc(?FAKE(Map), Json) -> ?FAKE(Map#{<<"doc">> => decode_map(Json)});
set_doc(Context, Json) -> write(Context, 'set_doc', decode(Json)).

%% @doc What the response's `data' will be.
-spec resp_data(context()) -> any().
resp_data(?FAKE(Map)) -> maps:get(<<"resp_data">>, Map, #{});
resp_data(Context) -> to_map_value(read(Context, 'resp_data', #{})).

-spec set_resp_data(context(), binary()) -> context().
set_resp_data(?FAKE(Map), Json) ->
    ?FAKE(Map#{<<"resp_data">> => json:decode(Json)});
set_resp_data(Context, Json) -> write(Context, 'set_resp_data', decode_any(Json)).

%% @doc `success', `error', `fatal' or `stop'. Crossbar only renders a
%% response body for `success'.
-spec resp_status(context()) -> binary().
resp_status(?FAKE(Map)) -> maps:get(<<"resp_status">>, Map, <<"error">>);
resp_status(Context) ->
    case read(Context, 'resp_status', 'error') of
        Status when is_atom(Status) -> atom_to_binary(Status, 'utf8');
        Status when is_binary(Status) -> Status;
        _Other -> <<"error">>
    end.

-spec set_resp_status(context(), binary()) -> context().
set_resp_status(?FAKE(Map), Status) -> ?FAKE(Map#{<<"resp_status">> => Status});
set_resp_status(Context, Status) ->
    write(Context, 'set_resp_status', binary_to_atom(Status, 'utf8')).

%% @doc Carry a value from one phase of the request to the next: what
%% `validate' worked out and `put' needs.
%% @doc The content types besides JSON this path can answer, as
%% `type/subtype' binaries. Crossbar keeps them as `to_binary' handlers and
%% negotiates with the request's `Accept'.
-spec set_content_types_provided(context(), [binary()]) -> context().
set_content_types_provided(?FAKE(Map), Types) ->
    ?FAKE(Map#{<<"content_types_provided">> => Types});
set_content_types_provided(Context, Types) ->
    write(Context, 'set_content_types_provided', [{'to_binary', [content_type(Type) || Type <- Types]}]).

-spec content_type(binary()) -> {binary(), binary(), []}.
content_type(Type) ->
    case binary:split(Type, <<"/">>) of
        [Major, Minor] -> {Major, Minor, []};
        [Major] -> {Major, <<"*">>, []}
    end.

%% @doc A raw body in the given content type, with a success status: what a
%% verb answers on a path whose `content_types_provided' named that type.
-spec set_resp_body(context(), binary(), binary()) -> context().
set_resp_body(?FAKE(Map), Body, ContentType) ->
    ?FAKE(Map#{<<"resp_body">> => Body
              ,<<"resp_content_type">> => ContentType
              ,<<"resp_status">> => <<"success">>
              });
set_resp_body(Context, Body, ContentType) ->
    Context1 = write(Context, 'set_resp_data', Body),
    Context2 = write(Context1, 'add_resp_headers', #{<<"content-type">> => ContentType}),
    set_resp_status(Context2, <<"success">>).

%% @doc The raw body `set_resp_body' answered, if the answer is one.
-spec resp_body(context()) -> {'ok', binary()} | {'error', 'nil'}.
resp_body(?FAKE(Map)) ->
    case maps:find(<<"resp_body">>, Map) of
        {'ok', Body} -> {'ok', Body};
        'error' -> {'error', 'nil'}
    end;
resp_body(Context) ->
    case read(Context, 'resp_data', 'undefined') of
        Body when is_binary(Body) -> {'ok', Body};
        _Other -> {'error', 'nil'}
    end.

-spec store(context(), binary(), binary()) -> context().
store(?FAKE(Map), Key, Json) ->
    Stored = maps:get(<<"store">>, Map, #{}),
    ?FAKE(Map#{<<"store">> => Stored#{Key => json:decode(Json)}});
store(Context, Key, Json) ->
    case loaded('cb_context') of
        'false' -> Context;
        'true' ->
            try cb_context:store(Context, Key, decode_any(Json))
            catch
                _E:_R -> Context
            end
    end.

-spec fetch(context(), binary()) -> {'ok', any()} | {'error', 'nil'}.
fetch(?FAKE(Map), Key) ->
    defined(maps:get(Key, maps:get(<<"store">>, Map, #{}), 'undefined'));
fetch(Context, Key) ->
    case loaded('cb_context') of
        'false' -> {'error', 'nil'};
        'true' ->
            try defined(to_map_value(cb_context:fetch(Context, Key)))
            catch
                _E:_R -> {'error', 'nil'}
            end
    end.

%%%=============================================================================
%%% Errors
%%%=============================================================================

%% @doc One field of the request is wrong, in the shape the schema validator
%% reports: the path to it, the rule it broke, and what to tell the client.
-spec add_validation_error(context(), [binary()], binary(), binary()) -> context().
add_validation_error(?FAKE(Map), Property, Code, Message) ->
    Errors = maps:get(<<"validation_errors">>, Map, []),
    ?FAKE(Map#{<<"validation_errors">> => Errors ++ [{Property, Code, Message}]
              ,<<"resp_status">> => <<"error">>
              });
add_validation_error(Context, Property, Code, Message) ->
    case loaded('cb_context') of
        'false' -> Context;
        'true' ->
            try cb_context:add_validation_error(Property, Code, Message, Context)
            catch
                _E:_R -> Context
            end
    end.

%% @doc The whole request fails for a reason Crossbar already has a status
%% code and a message for: `bad_identifier', `forbidden', `not_found',
%% `datastore_unreachable'.
-spec add_system_error(context(), binary()) -> context().
add_system_error(?FAKE(Map), Kind) ->
    ?FAKE(Map#{<<"system_error">> => Kind, <<"resp_status">> => <<"error">>});
add_system_error(Context, Kind) ->
    case loaded('cb_context') of
        'false' -> Context;
        'true' ->
            try cb_context:add_system_error(binary_to_atom(Kind, 'utf8'), Context)
            catch
                _E:_R -> Context
            end
    end.

%% @doc The whole request fails with a status code and a message of the
%% handler's own: a `409' Crossbar has no system error for, or a `404' that
%% says what was not there rather than `bad identifier'.
-spec add_error(context(), integer(), binary(), binary()) -> context().
add_error(?FAKE(Map), Code, Kind, Message) ->
    ?FAKE(Map#{<<"system_error">> => Kind
              ,<<"error_code">> => Code
              ,<<"error_message">> => Message
              ,<<"resp_status">> => <<"error">>
              });
add_error(Context, Code, Kind, Message) ->
    case loaded('cb_context') of
        'false' -> Context;
        'true' ->
            try cb_context:add_system_error(Code, Kind, Message, Context)
            catch
                _E:_R -> Context
            end
    end.

%%%=============================================================================
%%% Validation and documents
%%%=============================================================================

%% @doc Check the request body against a JSON schema by id. On success the
%% validated body is on the context as its document and `OnSuccess' runs; on
%% failure the context carries the errors and `OnSuccess' does not run.
-spec validate_request_data(binary(), context(), fun((context()) -> context())) ->
          context().
validate_request_data(SchemaId, Context, OnSuccess) ->
    case loaded('cb_context') of
        'false' -> OnSuccess(Context);
        'true' ->
            try cb_context:validate_request_data(SchemaId, Context, OnSuccess)
            catch
                _E:_R -> Context
            end
    end.

%% @doc Load a document into the context by id. `Type' is the `pvt_type' the
%% document must have, so that one noun cannot read another's documents;
%% empty accepts any.
-spec load_doc(context(), binary(), binary()) -> context().
load_doc(Context, DocId, Type) ->
    case loaded('crossbar_doc') of
        'false' -> Context;
        'true' ->
            try crossbar_doc:load(DocId, Context, [{'expected_type', type(Type)}])
            catch
                _E:_R -> Context
            end
    end.

-spec type(binary()) -> binary().
type(<<>>) -> <<"any">>;
type(Type) -> Type.

%% @doc Save the context's document, answering a context whose response data
%% is the saved document or whose status says why not.
-spec save_doc(context()) -> context().
save_doc(Context) ->
    case loaded('crossbar_doc') of
        'false' -> Context;
        'true' ->
            try crossbar_doc:save(Context)
            catch
                _E:_R -> Context
            end
    end.

%% @doc Merge the context's document -- the validated request body -- over the
%% stored one's private fields, so that a replace keeps the revision, the type
%% and everything else the client never sent.
-spec load_merge(context(), binary(), binary()) -> context().
load_merge(Context, DocId, Type) ->
    case loaded('crossbar_doc') of
        'false' -> Context;
        'true' ->
            try crossbar_doc:load_merge(DocId, Context, [{'expected_type', type(Type)}])
            catch
                _E:_R -> Context
            end
    end.

%% @doc Remove the context's document, as Crossbar removes anything: a soft
%% delete, which is what the views read as gone.
-spec delete_doc(context()) -> context().
delete_doc(Context) ->
    case loaded('crossbar_doc') of
        'false' -> Context;
        'true' ->
            try crossbar_doc:delete(Context)
            catch
                _E:_R -> Context
            end
    end.

%% @doc Load a document, apply the request body to it as a PATCH -- an
%% explicit null removes a key -- and run `Validate' over the result.
-spec patch_and_validate(context(), binary(), fun((binary(), context()) -> context())) ->
          context().
patch_and_validate(Context, DocId, Validate) ->
    case loaded('crossbar_doc') of
        'false' -> Validate(DocId, Context);
        'true' ->
            try crossbar_doc:patch_and_validate(DocId, Context, Validate)
            catch
                _E:_R -> Context
            end
    end.

%% @doc Run a view into the context's response data, with paging and the
%% `created_from' and `created_to' range Crossbar's own listings use.
-spec load_view(context(), binary(), binary()) -> context().
load_view(Context, View, OptionsJson) ->
    case loaded('crossbar_view') of
        'false' -> Context;
        'true' ->
            try crossbar_view:load(Context, View, view_options(decode_map(OptionsJson)))
            catch
                _E:_R -> Context
            end
    end.

%% @doc The view options a Gleam caller may set. Anything else is dropped
%% rather than passed through: the rest of `crossbar_view''s options are
%% functions, which do not travel as JSON.
-spec view_options(map()) -> list().
view_options(Map) ->
    lists:foldl(fun view_option/2, [], maps:to_list(Map)).

-spec view_option({binary(), any()}, list()) -> list().
view_option({<<"key">>, Value}, Acc) -> [{'key', Value} | Acc];
view_option({<<"startkey">>, Value}, Acc) -> [{'startkey', Value} | Acc];
view_option({<<"endkey">>, Value}, Acc) -> [{'endkey', Value} | Acc];
view_option({<<"limit">>, Value}, Acc) -> [{'limit', Value} | Acc];
view_option({<<"include_docs">>, 'true'}, Acc) -> ['include_docs' | Acc];
view_option({<<"descending">>, 'true'}, Acc) -> ['descending' | Acc];
view_option({<<"should_paginate">>, Value}, Acc) -> [{'should_paginate', Value} | Acc];
view_option({<<"unchunkable">>, Value}, Acc) -> [{'unchunkable', Value} | Acc];
view_option({<<"created_from">>, Value}, Acc) -> [{'created_from', Value} | Acc];
view_option({<<"created_to">>, Value}, Acc) -> [{'created_to', Value} | Acc];
view_option({<<"max_range">>, Value}, Acc) -> [{'max_range', Value} | Acc];
view_option(_Unknown, Acc) -> Acc.

%% @doc Start a Crossbar module and add it to the ones the node autoloads,
%% which is what an application does for its own nouns while it starts.
-spec start_module(binary()) -> 'nil'.
start_module(Module) ->
    _ = case loaded('crossbar_maintenance') of
            'false' -> 'ok';
            'true' ->
                try crossbar_maintenance:start_module(Module)
                catch
                    _E:_R -> 'ok'
                end
        end,
    'nil'.

%%%=============================================================================
%%% Internal
%%%=============================================================================

-spec read(context(), atom(), any()) -> any().
read(Context, Function, Default) ->
    case loaded('cb_context') of
        'false' -> Default;
        'true' ->
            try cb_context:Function(Context) of
                'undefined' -> Default;
                Value -> Value
            catch
                _E:_R -> Default
            end
    end.

-spec write(context(), atom(), any()) -> context().
write(Context, Function, Value) ->
    case loaded('cb_context') of
        'false' -> Context;
        'true' ->
            try cb_context:Function(Context, Value)
            catch
                _E:_R -> Context
            end
    end.

-spec at_path(map(), [binary()]) -> {'ok', any()} | {'error', 'nil'}.
at_path(Value, []) -> defined(Value);
at_path(Map, [Key | Rest]) when is_map(Map) ->
    case maps:find(Key, Map) of
        {'ok', Found} -> at_path(Found, Rest);
        'error' -> {'error', 'nil'}
    end;
at_path(_Value, _Path) -> {'error', 'nil'}.

-spec present(any()) -> {'ok', binary()} | {'error', 'nil'}.
present(<<>>) -> {'error', 'nil'};
present(Value) when is_binary(Value) -> {'ok', Value};
present(_Undefined) -> {'error', 'nil'}.

-spec defined(any()) -> {'ok', any()} | {'error', 'nil'}.
defined('undefined') -> {'error', 'nil'};
defined(Value) -> {'ok', Value}.

-spec as_map(any()) -> map().
as_map(Value) when is_map(Value) -> Value;
as_map(Value) ->
    case loaded('kz_json')
        andalso kz_json:is_json_object(Value)
    of
        'true' -> kz_json:to_map(Value);
        'false' -> #{}
    end.

%% @doc A value on its way out to Gleam, with every `kz_json' object in it
%% turned into a map. It recurses into lists because a listing's response
%% data is a list of objects, not an object: without this a Gleam module
%% reading back what it or `crossbar_view' put there sees the raw records.
-spec to_map_value(any()) -> any().
to_map_value(Values) when is_list(Values) ->
    [to_map_value(Value) || Value <- Values];
to_map_value(Value) ->
    case loaded('kz_json')
        andalso kz_json:is_json_object(Value)
    of
        'true' -> kz_json:to_map(Value);
        'false' -> Value
    end.

-spec loaded(atom()) -> boolean().
loaded(Module) ->
    case code:ensure_loaded(Module) of
        {'module', Module} -> 'true';
        {'error', _Reason} -> 'false'
    end.

-spec decode(binary()) -> any().
decode(Json) ->
    case loaded('kz_json') of
        'false' -> json:decode(Json);
        'true' -> kz_json:from_map(decode_map(Json))
    end.

%% @doc Response data is not always an object: a listing answers an array.
-spec decode_any(binary()) -> any().
decode_any(Json) ->
    case json:decode(Json) of
        Map when is_map(Map) -> decode(Json);
        List when is_list(List) -> [term(Item) || Item <- List];
        Other -> Other
    end.

-spec term(any()) -> any().
term(Map) when is_map(Map) ->
    case loaded('kz_json') of
        'false' -> Map;
        'true' -> kz_json:from_map(Map)
    end;
term(Other) -> Other.

-spec decode_map(binary()) -> map().
decode_map(Json) ->
    case json:decode(Json) of
        Map when is_map(Map) -> Map;
        _Other -> #{}
    end.
