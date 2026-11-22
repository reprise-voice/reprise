%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2026, Vonix LLC
%%% @doc When the fax receiver uploads a received fax.
%%%
%%% The inbox lists a received fax as soon as its document is saved, so the
%%% upload of its page starts at once rather than after a 5 s idle; it runs
%%% in its own process, and the receiver keeps handling messages meanwhile.
%%% A failed upload is still retried after the poll interval, and a channel
%%% destroy during an upload does not start a second one.
%%%
%%% This Source Code Form is subject to the terms of the Mozilla Public
%%% License, v. 2.0. If a copy of the MPL was not distributed with this
%%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%%
%%% @end
%%%-----------------------------------------------------------------------------
-module(fax_request_tests).

-include_lib("eunit/include/eunit.hrl").

-define(POLL_INTERVAL, 5000).

store_test_() ->
    {'foreach'
    ,fun setup/0
    ,fun cleanup/1
    ,[fun upload_starts_without_waiting/1
     ,fun destroy_during_upload_arms_no_timer/1
     ,fun destroy_while_a_retry_waits_keeps_the_timer/1
     ,fun failed_upload_retries_after_the_interval/1
     ]
    }.

setup() ->
    Test = self(),
    meck:new('kapps_config', ['non_strict']),
    meck:expect('kapps_config', 'get_binary', fun(_Cat, _Key, Default) -> Default end),
    meck:new('kapps_call_command', ['non_strict']),
    meck:expect('kapps_call_command', 'store_file'
               ,fun(_File, _UrlFun, _Call) ->
                        Test ! {'store_file', self()},
                        receive {'finish', Result} -> Result end
                end
               ),
    Test.

cleanup(_) ->
    meck:unload(['kapps_config', 'kapps_call_command']).

upload_starts_without_waiting(_) ->
    Previous = spawn_monitor(fun() -> 'ok' end),
    Reply = fax_request:handle_cast({'store_attachment', kz_json:new()}
                                   ,fax_request:storing_state(kapps_call:new(), Previous)
                                   ),
    %% handle_cast has returned while the upload is still in store_file
    Uploader = receive {'store_file', Pid} -> Pid after 1000 -> 'undefined' end,
    Alive = is_pid(Uploader) andalso is_process_alive(Uploader),
    finish(Uploader, 'ok'),
    Reported = next_cast(),
    [?_assertMatch({'noreply', _}, Reply)
    ,?_assert(Alive)
    ,?_assertEqual({'$gen_cast', 'success'}, Reported)
    ].

destroy_during_upload_arms_no_timer(_) ->
    Uploader = spawn(fun() -> receive 'stop' -> 'ok' end end),
    Reply = fax_request:handle_cast({'channel_event', <<"CHANNEL_DESTROY">>, kz_json:new()}
                                   ,fax_request:storing_state(kapps_call:new(), {Uploader, make_ref()})
                                   ),
    Uploader ! 'stop',
    ?_assertMatch({'noreply', _}, Reply).

destroy_while_a_retry_waits_keeps_the_timer(_) ->
    {Gone, Ref} = spawn_monitor(fun() -> 'ok' end),
    receive {'DOWN', Ref, 'process', Gone, _} -> 'ok' end,
    Reply = fax_request:handle_cast({'channel_event', <<"CHANNEL_DESTROY">>, kz_json:new()}
                                   ,fax_request:storing_state(kapps_call:new(), {Gone, Ref})
                                   ),
    ?_assertMatch({'noreply', _, ?POLL_INTERVAL}, Reply).

failed_upload_retries_after_the_interval(_) ->
    {Uploader, Ref} = spawn_monitor(fun() -> 'ok' end),
    Reply = fax_request:handle_cast({'retry_store_attachment', 'timeout'}
                                   ,fax_request:storing_state(kapps_call:new(), {Uploader, Ref})
                                   ),
    ?_assertMatch({'noreply', _, ?POLL_INTERVAL}, Reply).

finish('undefined', _) -> 'ok';
finish(Uploader, Result) -> Uploader ! {'finish', Result}.

next_cast() ->
    receive {'$gen_cast', _}=Cast -> Cast after 1000 -> 'none' end.
