%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2026, Vonix LLC
%%% @doc The Erlang side of `kazoo/modb': the account's month databases.
%%%
%%% This Source Code Form is subject to the terms of the Mozilla Public
%%% License, v. 2.0. If a copy of the MPL was not distributed with this
%%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%%
%%% A MODb is one database per account per month. `kazoo_modb' creates the
%%% month on the first write, so nothing here has to check whether it exists.
%%%
%%% Every timestamp is in Gregorian seconds -- seconds since year 0, which is
%%% what `kz_time:now_s/0' answers and what every stored Kazoo timestamp is,
%%% 62167219200 more than the unix second of the same instant.
%%% @end
%%%-----------------------------------------------------------------------------
-module(kazoo_gleam_modb_ffi).

-export([db_name/2
        ,save_doc/5
        ,open_doc/3
        ,get_results/4
        ,get_range/3
        ,now_s/0
        ,year_month/1
        ]).

%% Seconds between year 0 and the unix epoch: `?UNIX_EPOCH_IN_GREGORIAN' in
%% `kazoo_stdlib/include/kz_types.hrl', repeated here because a
%% gleam-compiled file has no include path.
-define(UNIX_EPOCH_IN_GREGORIAN, 62167219200).

%% @doc The name of the account's month database, in the encoded form the
%% data layer uses: `account%2Fab%2Fcd%2Fef...-202609'. `At' zero means this
%% month.
-spec db_name(binary(), integer()) -> binary().
db_name(AccountId, 0) -> db_name(AccountId, now_s());
db_name(AccountId, At) ->
    case loaded('kazoo_modb') of
        'false' -> local_db_name(AccountId, At);
        'true' ->
            try kazoo_modb:get_modb(AccountId, At) of
                Db when is_binary(Db) -> Db;
                _Other -> local_db_name(AccountId, At)
            catch
                _E:_R -> local_db_name(AccountId, At)
            end
    end.

%% @doc The same name, worked out here, for a node with no data layer. The
%% encoded form is what `kazoo_modb:get_modb/2' answers for an account id,
%% and an account id is thirty-two hexadecimal characters; anything else is
%% already a database name and only takes the suffix.
-spec local_db_name(binary(), integer()) -> binary().
local_db_name(AccountId, At) ->
    {{Year, Month, _Day}, _Time} = calendar:gregorian_seconds_to_datetime(At),
    Suffix = <<"-", (integer_to_binary(Year))/binary, (pad_month(Month))/binary>>,
    case AccountId of
        <<A:2/binary, B:2/binary, Rest:28/binary>> ->
            <<"account%2F", A/binary, "%2F", B/binary, "%2F", Rest/binary, Suffix/binary>>;
        _NotAnId ->
            <<AccountId/binary, Suffix/binary>>
    end.

-spec pad_month(integer()) -> binary().
pad_month(Month) when Month < 10 -> <<"0", (integer_to_binary(Month))/binary>>;
pad_month(Month) -> integer_to_binary(Month).

%% @doc Write a document into the month `At' falls in, creating that month on
%% demand. The private fields go on the way that `cdr_util' writes a CDR:
%% the document type, the account, and the database the document belongs to.
-spec save_doc(binary(), binary(), binary(), integer(), integer()) ->
          {'ok', map()} | {'error', binary()}.
save_doc(AccountId, Json, Type, At, MaxRetries) ->
    Timestamp = case At of
                    0 -> now_s();
                    _ -> At
                end,
    case loaded('kazoo_modb') of
        'false' -> {'error', <<"unavailable">>};
        'true' ->
            try
                Db = kazoo_modb:get_modb(AccountId, Timestamp),
                Doc = kz_doc:update_pvt_parameters(kz_json:from_map(decode_map(Json))
                                                  ,Db
                                                  ,[{'type', binary_to_atom(Type, 'utf8')}
                                                   ,{'account_id', AccountId}
                                                   ,{'now', Timestamp}
                                                   ]
                                                  ),
                answer(kazoo_modb:save_doc(AccountId, Doc, Timestamp
                                          ,[{'max_retries', MaxRetries}]
                                          ))
            catch
                _E:_R -> {'error', <<"unavailable">>}
            end
    end.

-spec open_doc(binary(), binary(), integer()) -> {'ok', map()} | {'error', binary()}.
open_doc(AccountId, DocId, At) ->
    Timestamp = case At of
                    0 -> now_s();
                    _ -> At
                end,
    case loaded('kazoo_modb') of
        'false' -> {'error', <<"unavailable">>};
        'true' ->
            try answer(kazoo_modb:open_doc(AccountId, DocId, Timestamp))
            catch
                _E:_R -> {'error', <<"unavailable">>}
            end
    end.

%% @doc A view over the month `At' falls in. `kazoo_modb:get_results/3' takes
%% the month from the view options, so they carry it.
-spec get_results(binary(), binary(), binary(), integer()) ->
          {'ok', [map()]} | {'error', binary()}.
get_results(AccountId, View, OptionsJson, At) ->
    Timestamp = case At of
                    0 -> now_s();
                    _ -> At
                end,
    case loaded('kazoo_modb') of
        'false' -> {'error', <<"unavailable">>};
        'true' ->
            try
                {{Year, Month, _Day}, _Time} = calendar:gregorian_seconds_to_datetime(Timestamp),
                Options = [{'year', Year}, {'month', Month}
                           | view_options(decode_map(OptionsJson))
                          ],
                case kazoo_modb:get_results(AccountId, View, Options) of
                    {'ok', JObjs} -> {'ok', [kz_json:to_map(JObj) || JObj <- JObjs]};
                    {'error', Reason} -> {'error', reason(Reason)}
                end
            catch
                _E:_R -> {'error', <<"unavailable">>}
            end
    end.

%% @doc Every month database between two instants, oldest first. The
%% databases are not checked for existence; a view over one that is not there
%% answers `db_not_found'.
-spec get_range(binary(), integer(), integer()) -> [binary()].
get_range(AccountId, From, To) ->
    case loaded('kazoo_modb') of
        'false' -> [];
        'true' ->
            try kazoo_modb:get_range(AccountId, From, To) of
                Dbs when is_list(Dbs) -> Dbs;
                _Other -> []
            catch
                _E:_R -> []
            end
    end.

%% @doc Now, in Gregorian seconds, which is the only kind of timestamp Kazoo
%% stores.
-spec now_s() -> integer().
now_s() -> erlang:system_time('second') + ?UNIX_EPOCH_IN_GREGORIAN.

%% @doc The year and month a Gregorian second falls in.
-spec year_month(integer()) -> {integer(), integer()}.
year_month(At) ->
    {{Year, Month, _Day}, _Time} = calendar:gregorian_seconds_to_datetime(At),
    {Year, Month}.

%%%=============================================================================
%%% Internal
%%%=============================================================================

-spec answer(any()) -> {'ok', map()} | {'error', binary()}.
answer({'ok', JObj}) -> {'ok', kz_json:to_map(JObj)};
answer({'error', Reason}) -> {'error', reason(Reason)};
answer(_Other) -> {'error', <<"unavailable">>}.

-spec view_options(map()) -> list().
view_options(Map) ->
    lists:foldl(fun view_option/2, [], maps:to_list(Map)).

-spec view_option({binary(), any()}, list()) -> list().
view_option({<<"key">>, Value}, Acc) -> [{'key', Value} | Acc];
view_option({<<"startkey">>, Value}, Acc) -> [{'startkey', Value} | Acc];
view_option({<<"endkey">>, Value}, Acc) -> [{'endkey', Value} | Acc];
view_option({<<"limit">>, Value}, Acc) -> [{'limit', Value} | Acc];
view_option({<<"skip">>, Value}, Acc) -> [{'skip', Value} | Acc];
view_option({<<"include_docs">>, 'true'}, Acc) -> ['include_docs' | Acc];
view_option({<<"descending">>, 'true'}, Acc) -> ['descending' | Acc];
view_option({<<"reduce">>, Value}, Acc) -> [{'reduce', Value} | Acc];
view_option(_Unknown, Acc) -> Acc.

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
