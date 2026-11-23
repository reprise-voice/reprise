%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2026, Vonix LLC
%%% @doc The Erlang side of the Kazoo bindings for Gleam applications.
%%%
%%% This Source Code Form is subject to the terms of the Mozilla Public
%%% License, v. 2.0. If a copy of the MPL was not distributed with this
%%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%%
%%% Everything the Gleam code needs from the VM or from Kazoo goes through
%%% here. Each call falls back to a value that makes sense on its own, so an
%%% application still starts, and its test suite still runs, outside a Kazoo
%%% release where `kapps_config' is not loaded and the datastore is absent.
%%%
%%% Nothing here is bound to one application: the application's name and its
%%% own database are arguments, not macros.
%%% @end
%%%-----------------------------------------------------------------------------
-module(kazoo_gleam_ffi).

-export([mark_kazoo_app/2
        ,classify_db/1
        ,config_get_integer/3
        ,config_get_string/3
        ,config_get_json/2
        ,config_set_default/3
        ,node_name/0
        ,app_version/1
        ,request_id/0
        ,priv_dir/1
        ,now_s/0
        ,iso8601/1
        ,random_string/1
        ,open_cache_doc/2
        ,open_doc/2
        ,open_revision/3
        ,flush_cache_doc/2
        ,save_doc/2
        ,del_doc/2
        ,get_results/3
        ,db_exists/1
        ,db_create/1
        ,account_ids/0
        ,validate_token/1
        ,create_token/1
        ,alert/7
        ,log_error/1
        ,log_info/1
        ,publish_check_sync/4
        ]).

%% Every database an application on this node has declared to be a system
%% database, so that `classify_db/1' -- which the data layer calls with the
%% database and nothing else -- can answer without a closure and without a
%% module per application.
-define(SYSTEM_DBS, {'kazoo_gleam', 'system_dbs'}).

%% The alphabet generated passwords are drawn from: URL safe, so a password
%% survives a provisioning URL of the `https://user:password@host/' form, and
%% every character is typeable on a handset keypad.
-define(PASSWORD_ALPHABET
       ,<<"abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789-_">>
       ).

%% @doc Tell `kapps_controller' `App' is one of its applications, the way
%% every Erlang application's .app.src does with `{is_kazoo_app, true}', and
%% register `SystemDb' as a system database. The Gleam compiler owns the
%% generated .app file and has no way to put an `env' entry in it, so the
%% application sets it on itself while starting, before
%% `kapps_controller:start_app/1' reads it back.
%%
%% `SystemDb' is empty for an application that has no database of its own.
-spec mark_kazoo_app(binary(), binary()) -> 'nil'.
mark_kazoo_app(App, SystemDb) ->
    _ = classify_system_db(SystemDb),
    _ = application:set_env(binary_to_atom(App, 'utf8'), 'is_kazoo_app', 'true'),
    'nil'.

%% @doc Tell the data layer that `Database' is a system database.
%%
%% `kzs_util:db_classification/1' knows the databases Kazoo ships and warns,
%% with a stack trace, for every read of one it does not -- which would be
%% every view an application runs against its own database.
%% `bind_db_classify/3' is the extension point for exactly this.
-spec classify_system_db(binary()) -> 'ok'.
classify_system_db(<<>>) -> 'ok';
classify_system_db(Database) ->
    _ = remember_system_db(Database),
    case code:ensure_loaded('kzs_util') of
        {'error', _Reason} -> 'ok';
        {'module', 'kzs_util'} ->
            try kzs_util:bind_db_classify(Database, ?MODULE, 'classify_db') of
                _Bound -> 'ok'
            catch
                _E:_R -> 'ok'
            end
    end.

-spec remember_system_db(binary()) -> 'ok'.
remember_system_db(Database) ->
    Known = system_dbs(),
    case lists:member(Database, Known) of
        'true' -> 'ok';
        'false' -> persistent_term:put(?SYSTEM_DBS, [Database | Known])
    end.

-spec system_dbs() -> [binary()].
system_dbs() -> persistent_term:get(?SYSTEM_DBS, []).

%% @doc The classification callback. The binding is per database, so this is
%% only ever called with a database some application registered; the list is
%% consulted anyway so that a stray binding cannot make a foreign database a
%% system one.
-spec classify_db(binary()) -> atom().
classify_db(Database) ->
    case lists:member(Database, system_dbs()) of
        'true' -> 'system';
        'false' -> 'undefined'
    end.

%% @doc `system_config/<Category>.<Key>', or `Default' when the document,
%% the key or the datastore itself is not there.
%%
%% Read with `kapps_config:get/2', never with a default: `get/3' writes the
%% default into the document when the key is absent (`get_default_value/4'
%% calls `set/3'), so a reader that passes a placeholder -- an empty string
%% for an enum, a boolean or a number -- leaves a document no schema accepts
%% and no Crossbar write can then replace. `get/2' asks with `undefined',
%% which `update_category/5' refuses to store. The default lives in Gleam.
-spec config_get_integer(binary(), binary(), integer()) -> integer().
config_get_integer(Category, Key, Default) ->
    case code:ensure_loaded('kapps_config') of
        {'module', 'kapps_config'} ->
            try kapps_config:get(Category, Key) of
                'undefined' -> Default;
                Value -> kz_term:safe_cast(Value, Default, fun kz_term:to_integer/1)
            catch
                _E:_R -> Default
            end;
        {'error', _Reason} -> Default
    end.

%% @doc The name of the Erlang node serving the request.
-spec node_name() -> binary().
node_name() -> atom_to_binary(node(), 'utf8').

%% @doc An application's version, which is the one in its gleam.toml (the
%% Gleam compiler writes it into the generated .app file).
-spec app_version(binary()) -> binary().
app_version(App) ->
    Application = binary_to_atom(App, 'utf8'),
    _ = application:load(Application),
    case application:get_key(Application, 'vsn') of
        {'ok', Vsn} -> iolist_to_binary(Vsn);
        'undefined' -> <<"unknown">>
    end.

%% @doc A random identifier for the `request_id' of a response envelope.
-spec request_id() -> binary().
request_id() -> binary:encode_hex(crypto:strong_rand_bytes(16), 'lowercase').

%% @doc `system_config/<Category>.<Key>' as a string. A boolean or a number
%% an operator stored as such (the console writes typed values) reads as its
%% text, the way `kapps_config:get_binary/3' would render it; an object or a
%% list is not a string and takes the default. Read without a default, for
%% the reason above `config_get_integer/3'.
-spec config_get_string(binary(), binary(), binary()) -> binary().
config_get_string(Category, Key, Default) ->
    case kapps_config_loaded() of
        'false' -> Default;
        'true' ->
            try kapps_config:get(Category, Key) of
                'undefined' -> Default;
                Value when is_binary(Value) -> Value;
                Value when is_boolean(Value); is_integer(Value); is_float(Value); is_atom(Value) ->
                    kz_term:to_binary(Value);
                _NotAScalar -> Default
            catch
                _E:_R -> Default
            end
    end.

%% @doc `system_config/<Category>.<Key>' as a map, for the key-type tables.
-spec config_get_json(binary(), binary()) -> {'ok', map()} | {'error', binary()}.
config_get_json(Category, Key) ->
    case kapps_config_loaded() of
        'false' -> {'error', <<"unavailable">>};
        'true' ->
            try kapps_config:get_json(Category, Key) of
                'undefined' -> {'error', <<"not_found">>};
                JObj -> {'ok', kz_json:to_map(JObj)}
            catch
                _E:_R -> {'error', <<"unavailable">>}
            end
    end.

%% @doc Write the default of `system_config/<Category>.<Key>', leaving any
%% value an operator has set alone.
-spec config_set_default(binary(), binary(), binary()) -> {'ok', 'nil'} | {'error', binary()}.
config_set_default(Category, Key, Json) ->
    case kapps_config_loaded() of
        'false' -> {'error', <<"unavailable">>};
        'true' ->
            try kapps_config:set_default(Category, Key, decode(Json)) of
                {'ok', _} -> {'ok', 'nil'};
                {'error', Reason} -> {'error', reason(Reason)}
            catch
                _E:_R -> {'error', <<"unavailable">>}
            end
    end.

-spec kapps_config_loaded() -> boolean().
kapps_config_loaded() ->
    case code:ensure_loaded('kapps_config') of
        {'module', 'kapps_config'} -> 'true';
        {'error', _Reason} -> 'false'
    end.

%% @doc An application's priv directory, which is where its schemas, its
%% contract and its data files are read from. Falls back to the relative path
%% so that a checkout is usable without a built release, which is also what a
%% test run from the project root gets.
-spec priv_dir(binary()) -> binary().
priv_dir(App) ->
    case code:priv_dir(binary_to_atom(App, 'utf8')) of
        {'error', _Reason} -> <<"priv">>;
        Dir ->
            Priv = iolist_to_binary(Dir),
            case filelib:is_dir(Priv) of
                'true' -> Priv;
                'false' -> <<"priv">>
            end
    end.

%% @doc Unix time in seconds.
-spec now_s() -> integer().
now_s() -> erlang:system_time('second').

%% @doc Unix seconds as the RFC 3339 / ISO 8601 instant the contract uses.
-spec iso8601(integer()) -> binary().
iso8601(Seconds) ->
    list_to_binary(calendar:system_time_to_rfc3339(Seconds, [{'unit', 'second'}
                                                            ,{'offset', "Z"}
                                                            ])).

%% @doc `Length' characters drawn uniformly from the password alphabet.
-spec random_string(non_neg_integer()) -> binary().
random_string(Length) ->
    Size = byte_size(?PASSWORD_ALPHABET),
    << <<(binary:at(?PASSWORD_ALPHABET, rand_below(Size)))>>
       || _ <- lists:seq(1, Length)
    >>.

-spec rand_below(pos_integer()) -> non_neg_integer().
rand_below(Size) ->
    <<Byte:8>> = crypto:strong_rand_bytes(1),
    %% 256 is not a multiple of the alphabet size, so the modulus is biased by
    %% about a percent. Resampling the tail removes it.
    case Byte < (256 - (256 rem Size)) of
        'true' -> Byte rem Size;
        'false' -> rand_below(Size)
    end.

%%%=============================================================================
%%% kz_datamgr
%%%
%%% Documents cross the boundary as plain data: `kz_json:to_map/1' on the way
%%% out, decoded on the Gleam side, and `kz_json:from_map/1' over a decoded
%%% JSON binary on the way in. No kz_json term is ever handled in Gleam.
%%%=============================================================================

-spec open_cache_doc(binary(), binary()) -> {'ok', map()} | {'error', binary()}.
open_cache_doc(Db, DocId) ->
    datamgr(fun() -> kz_datamgr:open_cache_doc(Db, DocId) end, fun kz_json:to_map/1).

-spec open_doc(binary(), binary()) -> {'ok', map()} | {'error', binary()}.
open_doc(Db, DocId) ->
    datamgr(fun() -> kz_datamgr:open_doc(Db, DocId) end, fun kz_json:to_map/1).

%% @doc One revision of a document, deleted or not, with `_revisions' naming
%% it and its ancestors: CouchDB's `?rev=<Rev>&revs=true'. A superseded
%% revision whose body compaction has discarded is `not_found'.
-spec open_revision(binary(), binary(), binary()) -> {'ok', map()} | {'error', binary()}.
open_revision(Db, DocId, Rev) ->
    Options = [{<<"rev">>, Rev}, {<<"revs">>, <<"true">>}],
    datamgr(fun() -> kz_datamgr:open_doc(Db, DocId, Options) end, fun kz_json:to_map/1).

%% @doc Forget the cached copy of one document. Nothing to answer: a node
%% without the data layer has nothing cached either.
-spec flush_cache_doc(binary(), binary()) -> 'nil'.
flush_cache_doc(Db, DocId) ->
    _ = case datamgr_loaded() of
            'false' -> 'ok';
            'true' -> catch kz_datamgr:flush_cache_doc(Db, DocId)
        end,
    'nil'.

-spec save_doc(binary(), binary()) -> {'ok', map()} | {'error', binary()}.
save_doc(Db, Json) ->
    datamgr(fun() -> kz_datamgr:save_doc(Db, decode(Json)) end, fun kz_json:to_map/1).

-spec del_doc(binary(), binary()) -> {'ok', map()} | {'error', binary()}.
del_doc(Db, DocId) ->
    datamgr(fun() -> kz_datamgr:del_doc(Db, DocId) end, fun kz_json:to_map/1).

%% @doc A view, with its options expressed as a JSON object: `key',
%% `startkey', `endkey', `limit', `skip', `include_docs', `descending' and
%% `reduce'.
-spec get_results(binary(), binary(), binary()) -> {'ok', [map()]} | {'error', binary()}.
get_results(Db, View, OptionsJson) ->
    %% The options are built inside the call rather than before it: they go
    %% through `kz_json', so on a node without the data layer this has to be
    %% the same "unavailable" every other read is, not a crash.
    datamgr(fun() ->
                    Options = view_options(decode_map(OptionsJson)),
                    kz_datamgr:get_results(Db, View, Options)
            end
           ,fun(JObjs) -> [kz_json:to_map(JObj) || JObj <- JObjs] end
           ).

-spec view_options(map()) -> list().
view_options(Map) ->
    lists:foldl(fun view_option/2, [], maps:to_list(Map)).

-spec view_option({binary(), any()}, list()) -> list().
view_option({<<"key">>, Value}, Acc) -> [{'key', view_key(Value)} | Acc];
view_option({<<"startkey">>, Value}, Acc) -> [{'startkey', view_key(Value)} | Acc];
view_option({<<"endkey">>, Value}, Acc) -> [{'endkey', view_key(Value)} | Acc];
view_option({<<"limit">>, Value}, Acc) -> [{'limit', Value} | Acc];
view_option({<<"skip">>, Value}, Acc) -> [{'skip', Value} | Acc];
view_option({<<"include_docs">>, 'true'}, Acc) -> ['include_docs' | Acc];
view_option({<<"descending">>, 'true'}, Acc) -> ['descending' | Acc];
view_option({<<"reduce">>, Value}, Acc) -> [{'reduce', Value} | Acc];
view_option(_Unknown, Acc) -> Acc.

%% @doc A view key as the driver wants it. The options arrive as plain maps
%% from `json:decode/1', and a key may contain an object -- CouchDB's
%% collation puts objects last, so `[AccountId, {}]' is how a range over one
%% account is closed. couchbeam cannot encode a bare map, so every map in a
%% key becomes a `kz_json' object first.
-spec view_key(any()) -> any().
view_key(Map) when is_map(Map) -> kz_json:from_map(Map);
view_key(List) when is_list(List) -> [view_key(Element) || Element <- List];
view_key(Value) -> Value.

-spec db_exists(binary()) -> boolean().
db_exists(Db) ->
    case datamgr_loaded() of
        'false' -> 'false';
        'true' ->
            try kz_datamgr:db_exists(Db)
            catch _E:_R -> 'false'
            end
    end.

-spec db_create(binary()) -> boolean().
db_create(Db) ->
    case datamgr_loaded() of
        'false' -> 'false';
        'true' ->
            try kz_datamgr:db_create(Db)
            catch _E:_R -> 'false'
            end
    end.

%% @doc Every account id on the cluster, for the reconcile walk.
-spec account_ids() -> {'ok', [binary()]} | {'error', binary()}.
account_ids() ->
    case code:ensure_loaded('kapps_util') of
        {'error', _Reason} -> {'error', <<"unavailable">>};
        {'module', 'kapps_util'} ->
            try {'ok', kapps_util:get_all_accounts('raw')}
            catch _E:_R -> {'error', <<"unavailable">>}
            end
    end.

-spec datamgr(fun(() -> any()), fun((any()) -> any())) -> {'ok', any()} | {'error', binary()}.
datamgr(Call, Convert) ->
    case datamgr_loaded() of
        'false' -> {'error', <<"unavailable">>};
        'true' ->
            try Call() of
                {'ok', Result} -> {'ok', Convert(Result)};
                {'error', Reason} -> {'error', reason(Reason)};
                'ok' -> {'ok', #{}}
            catch
                _E:_R -> {'error', <<"unavailable">>}
            end
    end.

-spec datamgr_loaded() -> boolean().
datamgr_loaded() ->
    case code:ensure_loaded('kz_datamgr') of
        {'module', 'kz_datamgr'} -> 'true';
        {'error', _Reason} -> 'false'
    end.

%%%=============================================================================
%%% kz_auth, kapps_alert, kapi_switch
%%%=============================================================================

%% @doc Validate a Crossbar JWT and return its claims.
-spec validate_token(binary()) -> {'ok', map()} | {'error', binary()}.
validate_token(Token) ->
    case code:ensure_loaded('kz_auth') of
        {'error', _Reason} -> {'error', <<"unavailable">>};
        {'module', 'kz_auth'} ->
            try kz_auth:validate_token(Token) of
                {'ok', Claims} -> {'ok', kz_json:to_map(Claims)};
                {'error', Reason} -> {'error', reason(Reason)}
            catch
                _E:_R -> {'error', <<"invalid">>}
            end
    end.

%% @doc `kz_auth:create_token/1' over the claims as a JSON object: the signed
%% token, or why there is none. `kz_auth' fills in `iss' and the identity
%% signature; everything else -- `account_id', `owner_id', `method', `exp' --
%% is the caller's to name, in the shape `crossbar_auth' names them.
-spec create_token(binary()) -> {'ok', binary()} | {'error', binary()}.
create_token(ClaimsJson) ->
    case code:ensure_loaded('kz_auth') of
        {'error', _Reason} -> {'error', <<"unavailable">>};
        {'module', 'kz_auth'} ->
            try kz_auth:create_token(kz_json:to_proplist(kz_json:decode(ClaimsJson))) of
                {'ok', Token} -> {'ok', Token};
                {'error', Reason} -> {'error', reason(Reason)}
            catch
                _E:_R -> {'error', <<"unavailable">>}
            end
    end.

%% @doc Write one line to the Kazoo log at error level, for what an operator
%% has to see.
%%
%% Guarded, unlike the `lager:log/4' calls an application makes from its own
%% Erlang modules: those only ever run on a node, and this is reached from
%% paths a test suite exercises, where there is no lager to reach.
-spec log_error(binary()) -> 'nil'.
log_error(Message) ->
    _ = case code:ensure_loaded('lager') of
            {'module', 'lager'} -> lager:log('error', self(), "~s", [Message]);
            {'error', _Reason} -> logger:error("~s", [Message])
        end,
    'nil'.

%% @doc Write one line to the Kazoo log at info level, for what an operator
%% reads back afterwards rather than acts on now: a lifecycle transition, a
%% piece of work taken up or handed on.
%%
%% Guarded the same way `log_error/1' is, and for the same reason.
-spec log_info(binary()) -> 'nil'.
log_info(Message) ->
    _ = case code:ensure_loaded('lager') of
            {'module', 'lager'} -> lager:log('info', self(), "~s", [Message]);
            {'error', _Reason} -> logger:info("~s", [Message])
        end,
    'nil'.

%% @doc Raise a Kazoo alert to the account's and the reseller's admins, the
%% way `provisioner_v5:create_alert/4' does for a failed push.
-spec alert(binary(), binary(), binary(), binary(), binary(), binary(), binary()) ->
          {'ok', 'nil'} | {'error', binary()}.
alert(Category, Title, Message, AccountId, OwnerId, ResellerId, MetadataJson) ->
    case code:ensure_loaded('kapps_alert') of
        {'error', _Reason} -> {'error', <<"unavailable">>};
        {'module', 'kapps_alert'} ->
            try alert(Category, Title, Message, AccountId, OwnerId, ResellerId
                     ,MetadataJson
                     ,kapps_alert:enabled()
                     )
            catch _E:_R -> {'error', <<"unavailable">>}
            end
    end.

-spec alert(binary(), binary(), binary(), binary(), binary(), binary(), binary(), boolean()) ->
          {'ok', 'nil'} | {'error', binary()}.
alert(_Category, _Title, _Message, _AccountId, _OwnerId, _ResellerId, _MetadataJson, 'false') ->
    {'ok', 'nil'};
alert(Category, Title, Message, AccountId, OwnerId, ResellerId, MetadataJson, 'true') ->
    From = [kz_json:from_list([{<<"type">>, <<"account">>}, {<<"value">>, AccountId}])
           ,kz_json:from_list([{<<"type">>, <<"user">>}, {<<"value">>, null_if_empty(OwnerId)}])
           ],
    To = [kz_json:from_list([{<<"type">>, AccountId}, {<<"value">>, <<"admins">>}])
         ,kz_json:from_list([{<<"type">>, null_if_empty(ResellerId)}, {<<"value">>, <<"admins">>}])
         ],
    Props = [{<<"metadata">>, decode(MetadataJson)}
            ,{<<"category">>, Category}
            ],
    {'ok', AlertJObj} = kapps_alert:create(Title, Message, From, To, Props),
    {'ok', _} = kapps_alert:save(AlertJObj),
    {'ok', 'nil'}.

-spec null_if_empty(binary()) -> binary() | 'undefined'.
null_if_empty(<<>>) -> 'undefined';
null_if_empty(Value) -> Value.

%% @doc Publish a check-sync NOTIFY for one registration, the same message
%% `provisioner_util:send_check_sync/5' publishes.
-spec publish_check_sync(binary(), binary(), binary(), binary()) ->
          {'ok', 'nil'} | {'error', binary()}.
publish_check_sync(App, Event, Realm, Username) ->
    case code:ensure_loaded('kapi_switch') of
        {'error', _Reason} -> {'error', <<"unavailable">>};
        {'module', 'kapi_switch'} ->
            Req = [{<<"Event">>, Event}
                  ,{<<"Realm">>, Realm}
                  ,{<<"Username">>, Username}
                   | kz_api:default_headers(App, app_version(App))
                  ],
            try
                'ok' = kz_amqp_worker:cast(Req, fun kapi_switch:publish_notify/1),
                {'ok', 'nil'}
            catch _E:_R -> {'error', <<"unavailable">>}
            end
    end.

%%%=============================================================================
%%% JSON
%%%=============================================================================

%% @doc A JSON binary as a kz_json object.
-spec decode(binary()) -> kz_json:object().
decode(Json) -> kz_json:from_map(decode_map(Json)).

-spec decode_map(binary()) -> map().
decode_map(Json) ->
    case json:decode(Json) of
        Map when is_map(Map) -> Map;
        Other -> #{<<"value">> => Other}
    end.

-spec reason(any()) -> binary().
reason(Reason) when is_atom(Reason) -> atom_to_binary(Reason, 'utf8');
reason(Reason) when is_binary(Reason) -> Reason;
reason(Reason) -> iolist_to_binary(io_lib:format("~p", [Reason])).
