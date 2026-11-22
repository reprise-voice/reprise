%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2023-2025, 2600Hz
%%% @doc Implements KAZOO style as an elvis rules module (elvis_core 4.x rule
%%% API). This is used by the elvis config to check some styles that are not
%%% built in by default.
%%% @end
%%%-----------------------------------------------------------------------------
-module(kz_style).

-export([no_unenclosed_atoms/2
        ,default/1
        ]).

%% This module only runs inside elvis (`make elvis`, the kazoo_stdlib tests),
%% and elvis is a test-only dependency of kazoo_stdlib since the OTP 28 port:
%% in a plain build these callees are not in deps/, so xref is told they are
%% expected.
-ignore_xref([{elvis_file, parse_tree, 2}
             ,{elvis_file, path, 1}
             ,{elvis_result, new_item, 3}
             ,{elvis_rule, defmap, 1}
             ,{ktn_code, attr, 2}
             ,{ktn_code, content, 1}
             ,{ktn_code, node_attr, 2}
             ,{ktn_code, type, 1}
             ,{zipper, is_end, 1}
             ,{zipper, new, 4}
             ,{zipper, next, 1}
             ,{zipper, node, 1}
             ]).

%%------------------------------------------------------------------------------
%% @doc The rule's default options (elvis_rule callback): it has none.
%% @end
%%------------------------------------------------------------------------------
-spec default(atom()) -> elvis_rule:def().
default('no_unenclosed_atoms') -> elvis_rule:defmap(#{}).

%%------------------------------------------------------------------------------
%% @doc Ensure that all atoms are 'tickied', that is enclosed in single quotes.
%% @end
%%------------------------------------------------------------------------------
-spec no_unenclosed_atoms(elvis_rule:t(), elvis_config:t() | [elvis_config:t()]) ->
          [elvis_result:item()].
no_unenclosed_atoms(Rule, ElvisConfig) ->
    {Root, File} = elvis_file:parse_tree(Rule, ElvisConfig),

    Path = elvis_file:path(File),

    Zipper = all_nodes_zipper(Root),
    AtomNodes = seek_atoms(Zipper),

    lists:foldr(fun(AtomNode, Acc) ->
                        fold_unenclosed_atom(AtomNode, Acc, Path)
                end
               ,[]
               ,AtomNodes
               ).

%%------------------------------------------------------------------------------
%% @doc The meaty potatoes. This takes an atom node, checks for tickies, and if
%% not found, creates an elvis result stating as such.
%% @end
%%------------------------------------------------------------------------------
-type fold_acc() :: [elvis_result:item()].

-spec fold_unenclosed_atom(ktn_code:tree_node(), fold_acc(), file:filename_all()) ->
          fold_acc().
fold_unenclosed_atom(Node, Acc, Path) ->
    {LineNumber, _ColNumber} = ktn_code:attr('location', Node),
    AsString = ktn_code:attr('text', Node),
    FirstCharacter = hd(AsString),
    LastCharacter = hd(lists:reverse(AsString)),
    case {FirstCharacter, LastCharacter} of
        {$', $'} -> Acc;
        _NotTickies ->
            [elvis_result:new_item("unenclosed atom at ~s:~p"
                                  ,[Path, LineNumber]
                                  ,#{'node' => Node}
                                  )
            | Acc
            ]
    end.

-type code_zip() :: zipper:zipper(ktn_code:tree_node()).

%%------------------------------------------------------------------------------
%% @doc A zipper over every node of the tree, node attributes included (record
%% field names, map keys, remote module/function atoms live there, not in the
%% content). elvis_core 4.x only exports its content-only zipper; this is its
%% all-nodes one.
%% @end
%%------------------------------------------------------------------------------
-spec all_nodes_zipper(ktn_code:tree_node()) -> code_zip().
all_nodes_zipper(Root) ->
    IsBranch = fun(#{} = Node) ->
                       ktn_code:content(Node) =/= []
                           orelse maps:is_key('node_attrs', Node)
               end,
    Children = fun(#{'content' := Content, 'node_attrs' := NodeAttrs}) ->
                       Content ++ lists:flatten(maps:values(NodeAttrs));
                  (#{'node_attrs' := NodeAttrs}) ->
                       lists:flatten(maps:values(NodeAttrs));
                  (#{'content' := Content}) ->
                       Content
               end,
    MakeNode = fun(Node, _Children) -> Node end,
    zipper:new(IsBranch, Children, MakeNode, Root).

-spec seek_atoms(code_zip()) -> [ktn_code:tree_node()].
seek_atoms(Zipper) ->
    seek_atoms(zipper:is_end(Zipper), Zipper, sets:new(), []).

%%------------------------------------------------------------------------------
%% @doc The trouble is not every atom that is a record field reference is marked
%% as such. In a few instances, the atom for the field name is in the content
%% of the node, just as a plain atom, and things like the assignment of value
%% would be. Therefore, we have to go through bit by bit and ensure the atom
%% we're looking at is a 'plain atom' and not used as field name in a record.
%%
%% We store the nodes we find in a set under the assumption that when we dive
%% into the contents of a ktn_code:tree_node, it will be unadulterated by the
%% zipper, and so will match exactly.
%%
%% Also, external types have the module and function specified as atoms, which
%% we also don't want tickied.
%% @end
%%------------------------------------------------------------------------------
-spec seek_atoms(boolean(), code_zip(), sets:set(ktn_code:tree_node()), [ ktn_code:tree_node()]) -> [ktn_code:tree_node()].
seek_atoms('true', _, _, Acc) ->
    Acc;
seek_atoms('false', Zipper, SkipNodes, Acc) ->
    NewSkip = add_skippable_atoms(Zipper, SkipNodes),
    NewAcc = add_atoms(Zipper, SkipNodes, Acc),
    Next = zipper:next(Zipper),
    seek_atoms(zipper:is_end(Next), Next, NewSkip, NewAcc).

%%------------------------------------------------------------------------------
%% @doc If have a record field or index, extract the atom node that represents
%% the name, and add it to the skip set.
%% @end
%%------------------------------------------------------------------------------
-spec add_skippable_atoms(code_zip(), sets:set(ktn_code:tree_node())) -> sets:set(ktn_code:tree_node()).
add_skippable_atoms(Zipper, SkipNodes) ->
    Node = zipper:node(Zipper),
    add_skippable_atoms(Node, SkipNodes, ktn_code:type(Node)).

add_skippable_atoms(Node, SkipNodes, 'record_field') ->
    NameNode = extract_field_name(Node),
    sets:add_element(NameNode, SkipNodes);
add_skippable_atoms(Node, SkipNodes, 'record_index') ->
    NameNode = extract_field_name(Node),
    sets:add_element(NameNode, SkipNodes);
add_skippable_atoms(Node, SkipNodes, 'remote_type') ->
    add_module_and_function(Node, SkipNodes);
add_skippable_atoms(Node, SkipNodes, 'type') ->
    handle_type_node(Node, SkipNodes);
add_skippable_atoms(Node, SkipNodes, 'remote') ->
    add_module_and_function(Node, SkipNodes);
add_skippable_atoms(Node, SkipNodes, 'call') ->
    FuncNode = ktn_code:node_attr('function', Node),
    sets:add_element(FuncNode, SkipNodes);
add_skippable_atoms(Node, SkipNodes, 'map') ->
    sets:add_element(Node, SkipNodes);
add_skippable_atoms(Node, SkipNodes, 'map_field_exact') ->
    KeyNode = ktn_code:node_attr('key', Node),
    sets:add_element(KeyNode, SkipNodes);
add_skippable_atoms(Node, SkipNodes, 'map_field_assoc') ->
    add_skippable_map_keys(Node, SkipNodes);
add_skippable_atoms(_Node, SkipNodes, _Type) ->
    SkipNodes.

add_module_and_function(Node, SkipNodes) ->
    FuncNode = ktn_code:node_attr('function', Node),
    ModuleNode = ktn_code:node_attr('module', Node),
    sets:add_element(FuncNode, sets:add_element(ModuleNode, SkipNodes)).

handle_type_node(Node, SkipNodes) ->
    lists:foldl(fun(Fun, SN) -> Fun(Node, SN) end
               ,SkipNodes
               ,[fun maybe_has_record_name/2
                ,fun add_skippable_map_keys/2
                ]
               ).

maybe_has_record_name(Node, SkipNodes) ->
    maybe_has_record_name(Node, SkipNodes, ktn_code:attr('name', Node)).

maybe_has_record_name(Node, SkipNodes, 'record') ->
    maybe_has_record_atom(SkipNodes, extract_from_content(Node));
maybe_has_record_name(_Node, SkipNodes, _Type) ->
    SkipNodes.

maybe_has_record_atom(SkipNodes, 'undefined') -> SkipNodes;
maybe_has_record_atom(SkipNodes, AtomNode) -> sets:add_element(AtomNode, SkipNodes).

add_skippable_map_keys(Node, SkipNodes) ->
    add_skippable_map_keys(Node, SkipNodes, ktn_code:node_attr('content', Node)).

add_skippable_map_keys(Node, SkipNodes, 'undefined') ->
    case ktn_code:content(Node) of
        [MapKey, _Value] ->
            sets:add_element(MapKey, SkipNodes);
        _ ->
            case ktn_code:node_attr('key', Node) of
                'undefined' ->
                    SkipNodes;
                MapKey ->
                    sets:add_element(MapKey, SkipNodes)
            end
    end;
add_skippable_map_keys(_Node, SkipNodes, Content) ->
    %% 'content' is the internal content (between {...}) of the map syntax
    lists:foldl(fun(N, SNs) ->
                        add_skippable_atoms(N, SNs, ktn_code:type(N))
                end
               ,SkipNodes
               ,Content
               ).

%%------------------------------------------------------------------------------
%% @doc Try a few different ways to the field name atom node.
%% @end
%%------------------------------------------------------------------------------
-type extract_accumulator() :: 'undefined' | ktn_code:tree_node().

-spec extract_field_name(ktn_code:tree_node()) -> extract_accumulator().
extract_field_name(Node) ->
    Extractions =
        [fun extract_by_node_attr/1
        ,fun extract_from_content/1
        ],
    extract_until(Node, Extractions).

extract_until(_Node, []) -> 'undefined';
extract_until(Node, [Fun | Funs]) ->
    case Fun(Node) of
        'undefined' -> extract_until(Node, Funs);
        Value -> Value
    end.

%%------------------------------------------------------------------------------
%% @doc Util
%% @end
%%------------------------------------------------------------------------------
-spec extract_by_node_attr(ktn_code:tree_node()) -> 'undefined' | ktn_code:tree_node().
extract_by_node_attr(Node) ->
    ktn_code:node_attr('name', Node).

%%------------------------------------------------------------------------------
%% @doc Util
%% @end
%%------------------------------------------------------------------------------
-spec extract_from_content(ktn_code:tree_node()) -> 'undefined' | ktn_code:tree_node().
extract_from_content(Node) ->
    extract_from_content_item(ktn_code:content(Node)).

extract_from_content_item([AnItem]) ->
    extract_from_content_item(AnItem, ktn_code:type(AnItem));
extract_from_content_item(_Content) -> 'undefined'.

extract_from_content_item(AnItem, 'atom') -> AnItem;
extract_from_content_item(_AnItem, _Type) -> 'undefined'.

%%------------------------------------------------------------------------------
%% @doc Add the atom to the accumulator unless it is either not an atom or is a
%% member of the skip nodes set.
%% @end
%%------------------------------------------------------------------------------
-spec add_atoms(code_zip(), sets:set(ktn_code:tree_node()), [ktn_code:tree_node()]) ->
          [ktn_code:tree_node()].
add_atoms(Zipper, SkipNodes, Acc) ->
    Node = zipper:node(Zipper),
    case 'false' =:= sets:is_element(Node, SkipNodes) % not skipping this bare atom
        andalso 'atom' =:= ktn_code:type(Node) % the code node is an atom
    of
        'true' -> [Node | Acc];
        'false' -> Acc
    end.
