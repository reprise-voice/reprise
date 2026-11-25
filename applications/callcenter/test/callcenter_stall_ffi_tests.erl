%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2026, Vonix LLC
%%%
%%% This Source Code Form is subject to the terms of the Mozilla Public
%%% License, v. 2.0. If a copy of the MPL was not distributed with this
%%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%% @end
%%%-----------------------------------------------------------------------------
%% `callcenter_ffi''s half of the stall watch (`callcenter/stall'): the
%% notes it keeps in an array found through a persistent term, which say
%% nothing while no watch is registered, and the one reason a process ends
%% that is its supervisor shutting it down.
-module(callcenter_stall_ffi_tests).

-include_lib("eunit/include/eunit.hrl").

-define(KEY, {'callcenter', 'stall_watch'}).

notes_test_() ->
    {'setup'
    ,fun() -> persistent_term:erase(?KEY) end
    ,fun(_) -> persistent_term:erase(?KEY) end
    ,[{"no watch registered and no notes: nothing to say"
      ,fun() -> ?assertEqual({'error', 'nil'}, callcenter_ffi:stall_watch()) end
      }
     ,{"notes kept by a watch that is not running say nothing: every shard would be fenced for good"
      ,fun() ->
               'nil' = callcenter_ffi:stall_note(100, 'false'),
               ?assertEqual({'error', 'nil'}, callcenter_ffi:stall_watch())
       end
      }
     ,{"with the watch running: the last note, and a last stall before the first note"
      ,fun() ->
               with_watch(fun() ->
                                  ?assertEqual({'ok', {100, 99}}, callcenter_ffi:stall_watch()),
                                  'nil' = callcenter_ffi:stall_note(1100, 'false'),
                                  ?assertEqual({'ok', {1100, 99}}, callcenter_ffi:stall_watch())
                          end)
       end
      }
     ,{"a stall is the note that saw it, and stays the last stall"
      ,fun() ->
               with_watch(fun() ->
                                  'nil' = callcenter_ffi:stall_note(7100, 'true'),
                                  ?assertEqual({'ok', {7100, 7100}}, callcenter_ffi:stall_watch()),
                                  'nil' = callcenter_ffi:stall_note(8100, 'false'),
                                  ?assertEqual({'ok', {8100, 7100}}, callcenter_ffi:stall_watch())
                          end)
       end
      }
     ]
    }.

%% A process registered as the watch, for as long as `Fun' runs.
with_watch(Fun) ->
    Watch = spawn(fun() -> receive 'stop' -> 'ok' end end),
    'true' = register('callcenter_stall', Watch),
    try Fun()
    after
        unregister('callcenter_stall'),
        Watch ! 'stop'
    end.

shutdown_test_() ->
    [?_assert(callcenter_ffi:is_shutdown('shutdown'))
    ,?_assert(callcenter_ffi:is_shutdown({'shutdown', 'handed_over'}))
    ,?_assertNot(callcenter_ffi:is_shutdown('normal'))
    ,?_assertNot(callcenter_ffi:is_shutdown('killed'))
    ,?_assertNot(callcenter_ffi:is_shutdown({'badmatch', 'shutdown'}))
    ].
