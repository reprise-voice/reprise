%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2011-2023, 2600Hz
%%% @doc Listener for reg_success, and reg_query AMQP requests
%%% @author James Aimonetti
%%%
%%% This Source Code Form is subject to the terms of the Mozilla Public
%%% License, v. 2.0. If a copy of the MPL was not distributed with this
%%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%%
%%% @end
%%%-----------------------------------------------------------------------------
-module(ecallmgr_registrar_tests).

-include_lib("eunit/include/eunit.hrl").

-define(CONTACTS
       ,[{<<"sip:user_0tbp@1.1.1.1:55274;fs_path=sip:2.2.2.2:5060;lr;received='sip:1.1.1.1:55274;transport=udp'">>
         ,[{'transport', <<"udp">>}
          ,{'received', <<"1.1.1.1:55274">>}
          ,{'fs_path', <<"2.2.2.2:5060">>}
          ,{'uri', <<"user_0tbp@1.1.1.1:55274">>}
          ,{'hostport', <<"1.1.1.1:55274">>}
          ]
         }
        ,{<<"<sip:5519@2.2.2.2:55061;transport=TLS;ob;fs_path=<sip:1.1.1.1:5061;lr;received='sip:1.1.1.1:55061;transport=tls'>>">>
         ,[{'transport', <<"tls">>}
          ,{'received', <<"1.1.1.1:55061">>}
          ,{'fs_path', <<"1.1.1.1:5061">>}
          ,{'uri', <<"5519@2.2.2.2:55061">>}
          ,{'hostport', <<"2.2.2.2:55061">>}
          ]
         }
        ,{<<"<sip:User_2pnrza@3.3.3.3:64967;ob;fs_path=<sip:1.1.1.1:5060;lr;received='sip:3.3.3.3:64967;transport=udp'>>">>
         ,[{'transport', <<"udp">>}
          ,{'received', <<"3.3.3.3:64967">>}
          ,{'fs_path', <<"1.1.1.1:5060">>}
          ,{'uri', <<"User_2pnrza@3.3.3.3:64967">>}
          ,{'hostport', <<"3.3.3.3:64967">>}
          ]
         }
        ,{<<"<sip:5520@78.25.120.237:26070;transport=TLS;rinstance=e6b1e5bda0fcfd30;fs_path=<sip:94.125.5.31:5061;lr;received='sip:78.25.120.237:26070;transport=tls'>>">>
         ,[{'transport', <<"tls">>}
          ,{'received', <<"78.25.120.237:26070">>}
          ,{'fs_path', <<"94.125.5.31:5061">>}
          ,{'uri', <<"5520@78.25.120.237:26070">>}
          ,{'hostport', <<"78.25.120.237:26070">>}
          ]
         }
        ]).

registrar_summary_test_() ->
    lists:flatmap(fun contact_props/1, ?CONTACTS).

contact_props({Contact, Ps}) ->
    Props = ecallmgr_registrar:breakup_contact(Contact),
    [?_assertEqual(V, props:get_value(K, Props))
     || {K, V} <- Ps
    ].

%% The contact ecallmgr holds is the URI usrloc stores, without brackets. A
%% deregistration carries the request's Contact header as the SBC read it, a
%% FreeSWITCH registrar its own contact string, and a peer's fetch the held
%% form. Only the binding decides.
-define(HELD, <<"sip:stale-target@203.0.113.16:25060">>).

same_binding_test_() ->
    [{"same binding: " ++ binary_to_list(Contact)
     ,?_assert(ecallmgr_registrar:same_binding(?HELD, Contact))
     }
     || Contact <- [?HELD
                   ,<<"<sip:stale-target@203.0.113.16:25060>">>
                   ,<<"<sip:stale-target@203.0.113.16:25060>;expires=0">>
                   ,<<"<sip:stale-target@203.0.113.16:25060>;q=0;expires=600">>
                   ,<<"<sip:stale-target@203.0.113.16:25060>;+sip.instance=\"<urn:uuid:1>\"">>
                   ,<<"\"Stale\" <sip:stale-target@203.0.113.16:25060>;methods=\"INVITE, ACK\"">>
                   ,<<"sip:stale-target@203.0.113.16:25060;rinstance=abc">>
                   ,<<"sip:stale-target@203.0.113.16:25060;expires=0">>
                   ,<<"*">>
                   ]
    ]
        ++ [{"other binding: " ++ binary_to_list(Contact)
            ,?_assertNot(ecallmgr_registrar:same_binding(?HELD, Contact))
            }
            || Contact <- [<<"sip:stale-target@203.0.113.16:25062">>
                          ,<<"<sip:stale-target@203.0.113.16:25062>;expires=0">>
                          ,<<"sip:stale-target@203.0.113.17:25060">>
                          ,<<"sip:stale-target@203.0.113.16:25060;transport=tcp">>
                          ,<<"sip:other@203.0.113.16:25060">>
                          ,<<"sips:stale-target@203.0.113.16:25060">>
                          ]
           ]
        ++ [{"a missing port is 5060", ?_assert(same(<<"sip:u@1.2.3.4">>, <<"<sip:u@1.2.3.4:5060>">>))}
           ,{"a missing sips port is 5061", ?_assert(same(<<"sips:u@1.2.3.4">>, <<"<sips:u@1.2.3.4:5061>">>))}
           ,{"a missing sips port is not 5060", ?_assertNot(same(<<"sips:u@1.2.3.4">>, <<"sips:u@1.2.3.4:5060">>))}
           ,{"transport compares case-insensitively", ?_assert(same(<<"sip:u@h:5060;transport=tcp">>, <<"<sip:u@h:5060;transport=TCP>;expires=0">>))}
           ,{"a different transport is another binding", ?_assertNot(same(<<"sip:u@h:5060;transport=tcp">>, <<"sip:u@h:5060;transport=tls">>))}
           ,{"a transport is not implied", ?_assertNot(same(<<"sip:u@h:5060">>, <<"sip:u@h:5060;transport=udp">>))}
           ,{"host compares case-insensitively", ?_assert(same(<<"sip:u@Host.Example.COM">>, <<"<sip:u@host.example.com>">>))}
           ,{"scheme compares case-insensitively", ?_assert(same(<<"sip:u@h">>, <<"SIP:u@h">>))}
           ,{"user compares exactly", ?_assertNot(same(<<"sip:User@h">>, <<"sip:user@h">>))}
           ,{"an ipv6 host", ?_assert(same(<<"sip:u@[2001:db8::1]:5060;transport=tcp">>, <<"<sip:u@[2001:DB8::1]:5060;transport=tcp>">>))}
           ,{"a freeswitch contact against itself"
            ,?_assert(same(<<"sip:user_0tbp@1.1.1.1:55274;fs_path=sip:2.2.2.2:5060;lr;received='sip:1.1.1.1:55274;transport=udp'">>
                          ,<<"sip:user_0tbp@1.1.1.1:55274;fs_path=sip:2.2.2.2:5060;lr;received='sip:1.1.1.1:55274;transport=udp'">>
                          ))
            }
           ,{"a freeswitch contact on another port"
            ,?_assertNot(same(<<"sip:user_0tbp@1.1.1.1:55274;fs_path=sip:2.2.2.2:5060;lr">>
                             ,<<"sip:user_0tbp@1.1.1.1:55275;fs_path=sip:2.2.2.2:5060;lr">>
                             ))
            }
           ,{"an unparseable contact compares as a string", ?_assert(same(<<"\"user\" sip:u@h">>, <<"\"user\" <sip:u@h>">>))}
           ,{"an unparseable contact that differs", ?_assertNot(same(<<"\"user\" sip:u@h">>, <<"\"user\" <sip:u@h:5061>">>))}
           ].

same(Held, Contact) ->
    ecallmgr_registrar:same_binding(Held, Contact).
