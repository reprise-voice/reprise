%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2026, Vonix LLC
%%% @doc The Erlang behind the operator commands and the signer's edges:
%%% a send to a registered name that cannot raise, and the file calls
%%% `sup stir_maintenance import_key' needs to say why a file could not be
%%% read, how it is permissioned, and to take it away again.
%%%
%%% Same rules as `stir_ffi': compiled beside the Gleam sources, so no parse
%%% transform (no lager macros), no Kazoo header, and any call into a Kazoo
%%% module guarded with `code:ensure_loaded/1'. Nothing here reads, logs or
%%% returns the content of a key: `read_file/1' answers bytes the caller
%%% seals, and the rest answer a reason.
%%%
%%% This Source Code Form is subject to the terms of the Mozilla Public
%%% License, v. 2.0. If a copy of the MPL was not distributed with this
%%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%%
%%% @end
%%%-----------------------------------------------------------------------------
-module(stir_ops_ffi).

-export([send_named/2
        ,read_file/1
        ,file_mode/1
        ,delete_file/1
        ]).

%%------------------------------------------------------------------------------
%% @doc Send to a registered name without raising when nothing holds it.
%%
%% `gleam_erlang' asserts that a named subject resolves before it sends, so a
%% process that died between the lookup and the send takes the caller with it.
%% The caller here is a call on its way out: it gets `false' instead.
%%
%% The message is wrapped the way `gleam_erlang' wraps a send to a named
%% subject: `{Name, Message}', which is what an actor registered under that
%% name selects on.
%% @end
%%------------------------------------------------------------------------------
-spec send_named(atom(), any()) -> boolean().
send_named(Name, Message) ->
    try erlang:send(Name, {Name, Message}) of
        _Sent -> 'true'
    catch
        _Class:_Reason -> 'false'
    end.

%%------------------------------------------------------------------------------
%% @doc A file's bytes, or why they could not be read (`enoent', `eacces',
%% `eisdir', ...), as a binary rather than "cannot be read".
%% @end
%%------------------------------------------------------------------------------
-spec read_file(binary()) -> {'ok', binary()} | {'error', binary()}.
read_file(Path) ->
    case file:read_file(Path) of
        {'ok', Bytes} -> {'ok', Bytes};
        {'error', Reason} -> {'error', reason(Reason)}
    end.

%%------------------------------------------------------------------------------
%% @doc A file's mode, the permission bits included, as `file:read_file_info/1'
%% reports them: `33188' is `0100644', a regular file readable by everyone.
%%
%% The record is `#file_info{}' from `kernel/include/file.hrl', which this
%% module cannot include (no headers), so the field is taken by position:
%% `size, type, access, atime, mtime, ctime, mode, ...' makes `mode' the
%% seventh field and the eighth element. It has been that since R13.
%% @end
%%------------------------------------------------------------------------------
-spec file_mode(binary()) -> {'ok', non_neg_integer()} | {'error', binary()}.
file_mode(Path) ->
    case file:read_file_info(Path) of
        {'ok', Info} ->
            case element(8, Info) of
                Mode when is_integer(Mode) -> {'ok', Mode};
                _Other -> {'error', <<"unreadable file information">>}
            end;
        {'error', Reason} -> {'error', reason(Reason)}
    end.

%%------------------------------------------------------------------------------
%% @doc Remove a file: the key file an import has finished with.
%% @end
%%------------------------------------------------------------------------------
-spec delete_file(binary()) -> {'ok', 'nil'} | {'error', binary()}.
delete_file(Path) ->
    case file:delete(Path) of
        'ok' -> {'ok', 'nil'};
        {'error', Reason} -> {'error', reason(Reason)}
    end.

-spec reason(any()) -> binary().
reason(Reason) when is_atom(Reason) -> atom_to_binary(Reason, 'utf8');
reason(Reason) ->
    iolist_to_binary(io_lib:format("~p", [Reason])).
