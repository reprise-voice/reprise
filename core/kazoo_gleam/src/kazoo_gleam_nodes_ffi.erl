%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2026, Vonix LLC
%%% @doc What the cluster looks like from this node.
%%%
%%% This Source Code Form is subject to the terms of the Mozilla Public
%%% License, v. 2.0. If a copy of the MPL was not distributed with this
%%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%%
%%% `kz_nodes' keeps the table every node's heartbeat writes to. A node is
%%% described here the way `kz_node:to_json/1' describes it -- the record
%%% behind it is in a header this cannot include, and that projection is
%%% Kazoo's own.
%%%
%%% Everything degrades: a bare node has no cluster, so nothing is up, nobody
%%% is running anything, and the lists are empty.
%%% @end
%%%-----------------------------------------------------------------------------
-module(kazoo_gleam_nodes_ffi).

-export([is_up/1
        ,local_zone/0
        ,nodes/0
        ,whapp_count/1
        ,with_role/1
        ]).

%%------------------------------------------------------------------------------
%% @doc Whether that node is heartbeating.
%% @end
%%------------------------------------------------------------------------------
-spec is_up(binary()) -> boolean().
is_up(Node) ->
    case loaded() of
        'false' -> 'false';
        'true' -> is_up_node(Node)
    end.

%% A node Kazoo has heard from is an atom in this VM already; one that is not
%% is one nothing has heard from, and making the atom would be the only
%% lasting thing about it.
-spec is_up_node(binary()) -> boolean().
is_up_node(Node) ->
    try kz_nodes:is_up(binary_to_existing_atom(Node, 'utf8'))
    catch _E:_R -> 'false'
    end.

%%------------------------------------------------------------------------------
%% @doc The zone this node is in, spelled as `kz_node:to_json/1' spells a
%% node's; empty with no cluster.
%% @end
%%------------------------------------------------------------------------------
-spec local_zone() -> binary().
local_zone() ->
    case loaded() of
        'false' -> <<>>;
        'true' ->
            try kz_term:to_binary(kz_nodes:local_zone())
            catch _E:_R -> <<>>
            end
    end.

%%------------------------------------------------------------------------------
%% @doc Every node on the cluster.
%% @end
%%------------------------------------------------------------------------------
-spec nodes() -> [map()].
nodes() ->
    case loaded() of
        'false' -> [];
        'true' ->
            try node_maps(kz_nodes:nodes())
            catch _E:_R -> []
            end
    end.

%%------------------------------------------------------------------------------
%% @doc How many nodes are running that application.
%% @end
%%------------------------------------------------------------------------------
-spec whapp_count(binary()) -> integer().
whapp_count(Whapp) ->
    case loaded() of
        'false' -> 0;
        'true' ->
            try kz_nodes:whapp_count(Whapp)
            catch _E:_R -> 0
            end
    end.

%%------------------------------------------------------------------------------
%% @doc Every node with that role: `registrar', `dispatcher', whatever an
%% application has claimed.
%% @end
%%------------------------------------------------------------------------------
-spec with_role(binary()) -> [map()].
with_role(Role) ->
    case loaded() of
        'false' -> [];
        'true' ->
            try node_maps(kz_nodes:with_role(Role))
            catch _E:_R -> []
            end
    end.

-spec node_maps(list()) -> [map()].
node_maps(Nodes) -> [kz_json:to_map(kz_node:to_json(Node)) || Node <- Nodes].

-spec loaded() -> boolean().
loaded() ->
    case code:ensure_loaded('kz_nodes') of
        {'module', 'kz_nodes'} -> 'true';
        {'error', _Reason} -> 'false'
    end.
