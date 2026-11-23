# Rendered by entrypoint.sh from the environment (the configs' local.cfg is
# included first, so defines here win the trydefs downstream).
#
# NOTE on directives: MY_LOCAL_IP / MY_PUBLIC_IP must be #!define (they are
# consumed via $def(...) in listener-defs.cfg; a substdef would rewrite the
# text inside $def() itself and corrupt the listener tokens). Values consumed
# inside quoted strings (AMQP URL, DB URL, hostname) must be #!substdef.

## Roles (stock default set — dispatcher is load-bearing: default.cfg calls
## ds_* functions unguarded, so DISPATCHER_ROLE must stay on).
#!trydef DISPATCHER_ROLE
#!trydef NAT_TRAVERSAL_ROLE
#!trydef REGISTRAR_ROLE
#!trydef PRESENCE_ROLE
#!trydef RESPONDER_ROLE
#!trydef NODES_ROLE
## Push wake: an INVITE to an unregistered device carrying X-KAZOO-PUSHER-*
## headers is suspended while the pusher app wakes the device over AMQP
## (pusher-role.cfg). PUSH_NOTIFICATIONS_ROLE, where kamailio calls a push
## server over HTTP itself, stays off.
#!trydef PUSHER_ROLE
## TLS (5061 SIP, 7001 ALG) and secure websockets (5065): certificate from
## certs/cert.pem + certs/key.pem, linked by the entrypoint (Let's Encrypt
## for KAM_TLS_DOMAIN, self-signed fallback). Phones registering over
## TLS/WSS get the single-port proxy (7000/udp) in their path, so FreeSWITCH
## needs no TLS listener or certificate.
#!trydef TLS_ROLE
#!trydef WEBSOCKETS_ROLE
#!substdef "!MY_WEBSOCKET_DOMAIN!${MY_WEBSOCKET_DOMAIN}!g"

## Database: the configs' default db_kazoo (in-process sqlite) at
## /etc/kazoo/kamailio/db/kazoo.db, recreated by the entrypoint on start.

## Server identity. Listeners bind MY_LOCAL_IP via listener-defs.cfg tokens.
#!substdef "!MY_HOSTNAME!${MY_HOSTNAME}!g"
#!define MY_LOCAL_IP ${MY_LOCAL_IP}
#!define MY_PUBLIC_IP ${MY_PUBLIC_IP}

## Behind 1:1 NAT: bind the private NIC, advertise the public IP in
## Via/Record-Route/Contact for every socket. With the internal listener
## (MY_INTERNAL_IP; the entrypoint defines WITH_INTERNAL_LISTENER above this
## file) a global default would be advertised on that socket too, so there
## the per-socket advertise listeners below carry the public address alone.
#!ifndef WITH_INTERNAL_LISTENER
advertised_address="${MY_PUBLIC_IP}"
#!endif
# rr uses per-socket addresses: the global advertised_address alone leaves
# private Record-Route addresses in carrier dialogs behind GCE 1:1 NAT.
#!trydef WITHOUT_DEFAULT_LISTENER
#!trydef WITH_ADVERTISE_LISTENER
#!trydef WITH_ADVERTISE_TLS_LISTENER
#!trydef WITH_ADVERTISE_WEBSOCKETS_LISTENER

## AMQP
#!substdef "!MY_AMQP_ZONE!local!g"
#!substdef "!MY_AMQP_URL!${MY_AMQP_URL}!g"
