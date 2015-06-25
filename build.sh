#!/bin/sh
erl -pa /opt/ejabberd/ebin -pa /opt/ejabberd/deps/*/ebin -pz ebin -make -I /opt/ejabberd/include
