%%%-------------------------------------------------------------------
%%% @author Evgeniy Khramtsov <>
%%% @copyright (C) 2013, Evgeniy Khramtsov
%%% @doc
%%%
%%% @end
%%% Created : 27 Jun 2013 by Evgeniy Khramtsov <>
%%%-------------------------------------------------------------------
-module(suite).

%% API
-compile(export_all).

-include("suite.hrl").

%%%===================================================================
%%% API
%%%===================================================================
init_config(Config) ->
    DataDir = proplists:get_value(data_dir, Config),
    PrivDir = proplists:get_value(priv_dir, Config),
    [_, _|Tail] = lists:reverse(filename:split(DataDir)),
    BaseDir = filename:join(lists:reverse(Tail)),
    ConfigPathTpl = filename:join([DataDir, "ejabberd.yml"]),
    LogPath = filename:join([PrivDir, "ejabberd.log"]),
    SASLPath = filename:join([PrivDir, "sasl.log"]),
    MnesiaDir = filename:join([PrivDir, "mnesia"]),
    CertFile = filename:join([DataDir, "cert.pem"]),
    RevokedCertFile = filename:join([DataDir, "rev-cert.pem"]),
    {ok, CWD} = file:get_cwd(),
    {ok, _} = file:copy(CertFile, filename:join([CWD, "cert.pem"])),
    {ok, CfgContentTpl} = file:read_file(ConfigPathTpl),
    CfgContent = process_config_tpl(CfgContentTpl, [
                                                    {c2s_port, 5222},
                                                    {s2s_port, 5269},
                                                    {web_port, 5280},
                                                    {mysql_server, <<"localhost">>},
                                                    {mysql_port, 3306},
                                                    {mysql_db, <<"ejabberd_test">>},
                                                    {mysql_user, <<"ejabberd_test">>},
                                                    {mysql_pass, <<"ejabberd_test">>},
                                                    {pgsql_server, <<"localhost">>},
                                                    {pgsql_port, 5432},
                                                    {pgsql_db, <<"ejabberd_test">>},
                                                    {pgsql_user, <<"ejabberd_test">>},
                                                    {pgsql_pass, <<"ejabberd_test">>},
						    {data_dir, DataDir}
                                                   ]),
    ConfigPath = filename:join([CWD, "ejabberd.yml"]),
    ok = file:write_file(ConfigPath, CfgContent),
    ok = application:load(sasl),
    ok = application:load(mnesia),
    ok = application:load(ejabberd),
    application:set_env(ejabberd, config, ConfigPath),
    application:set_env(ejabberd, log_path, LogPath),
    application:set_env(sasl, sasl_error_logger, {file, SASLPath}),
    application:set_env(mnesia, dir, MnesiaDir),
    [{server_port, ct:get_config(c2s_port, 5222)},
     {server_host, "localhost"},
     {server, ?COMMON_VHOST},
     {user, <<"test_single">>},
     {master_nick, <<"master_nick">>},
     {slave_nick, <<"slave_nick">>},
     {room_subject, <<"hello, world!">>},
     {certfile, CertFile},
     {revoked_certfile, RevokedCertFile},
     {base_dir, BaseDir},
     {resource, <<"resource">>},
     {master_resource, <<"master_resource">>},
     {slave_resource, <<"slave_resource">>},
     {password, <<"password">>}
     |Config].

process_config_tpl(Content, []) ->
    Content;
process_config_tpl(Content, [{Name, DefaultValue} | Rest]) ->
    Val = case ct:get_config(Name, DefaultValue) of
              V1 when is_integer(V1) ->
                  list_to_binary(integer_to_list(V1));
              V2 when is_atom(V2) ->
                  atom_to_binary(V2, latin1);
              V3 when is_list(V3) ->
                  list_to_binary(V3);
              V4 ->
                  V4
          end,
    NewContent = binary:replace(Content, <<"@@",(atom_to_binary(Name, latin1))/binary, "@@">>, Val, [global]),
    process_config_tpl(NewContent, Rest).


connect(Config) ->
    {ok, Sock} = ejabberd_socket:connect(
                   ?config(server_host, Config),
                   ?config(server_port, Config),
                   [binary, {packet, 0}, {active, false}]),
    init_stream(set_opt(socket, Sock, Config)).

init_stream(Config) ->
    ok = send_text(Config, io_lib:format(?STREAM_HEADER,
                                          [?config(server, Config)])),
    {xmlstreamstart, <<"stream:stream">>, Attrs} = recv(),
    <<"jabber:client">> = xml:get_attr_s(<<"xmlns">>, Attrs),
    <<"1.0">> = xml:get_attr_s(<<"version">>, Attrs),
    StreamID = xml:get_attr_s(<<"id">>, Attrs),
    NewConfig = set_opt(stream_id, StreamID, Config),
    #stream_features{sub_els = Fs} = recv(),
    Mechs = lists:flatmap(
              fun(#sasl_mechanisms{list = Ms}) ->
                      Ms;
                 (_) ->
                      []
              end, Fs),
    lists:foldl(
      fun(#feature_register{}, Acc) ->
              set_opt(register, true, Acc);
         (#starttls{}, Acc) ->
              set_opt(starttls, true, Acc);
         (#compression{methods = Ms}, Acc) ->
              set_opt(compression, Ms, Acc);
	 (#p1_rebind{}, Acc) ->
	      set_opt(p1_rebind, true, Acc);
         (_, Acc) ->
              Acc
      end, set_opt(mechs, Mechs, NewConfig), Fs).

disconnect(Config) ->
    Socket = ?config(socket, Config),
    ok = ejabberd_socket:send(Socket, ?STREAM_TRAILER),
    {xmlstreamend, <<"stream:stream">>} = recv(),
    ejabberd_socket:close(Socket),
    Config.

close_socket(Config) ->
    Socket = ?config(socket, Config),
    ejabberd_socket:close(Socket),
    Config.

starttls(Config) ->
    starttls(Config, ?config(certfile, Config)).

starttls(Config, CertFile) ->
    send(Config, #starttls{}),
    #starttls_proceed{} = recv(),
    {ok, TLSSocket} = ejabberd_socket:starttls(
                        ?config(socket, Config),
                        [{certfile, CertFile},
                         connect]),
    init_stream(set_opt(socket, TLSSocket, Config)).

zlib(Config) ->
    send(Config, #compress{methods = [<<"zlib">>]}),
    #compressed{} = recv(),
    {ok, ZlibSocket} = ejabberd_socket:compress(?config(socket, Config)),
    init_stream(set_opt(socket, ZlibSocket, Config)).

auth(Config) ->
    Mechs = ?config(mechs, Config),
    HaveMD5 = lists:member(<<"DIGEST-MD5">>, Mechs),
    HavePLAIN = lists:member(<<"PLAIN">>, Mechs),
    if HavePLAIN ->
            auth_SASL(<<"PLAIN">>, Config, false);
       HaveMD5 ->
            auth_SASL(<<"DIGEST-MD5">>, Config, false);
       true ->
            ct:fail(no_sasl_mechanisms_available)
    end.

bind(Config) ->
    #iq{type = result, sub_els = [#bind{}]} =
        send_recv(
          Config,
          #iq{type = set,
              sub_els = [#bind{resource = ?config(resource, Config)}]}),
    Config.

open_session(Config) ->
    #iq{type = result, sub_els = []} =
        send_recv(Config, #iq{type = set, sub_els = [#session{}]}),
    Config.

auth_SASL(Mech, Config, ShouldFail) ->
    {Response, SASL} = sasl_new(Mech,
                                ?config(user, Config),
                                ?config(server, Config),
                                ?config(password, Config)),
    send(Config, #sasl_auth{mechanism = Mech, text = Response}),
    wait_auth_SASL_result(set_opt(sasl, SASL, Config), ShouldFail).

wait_auth_SASL_result(Config, ShouldFail) ->
    case recv() of
        #sasl_success{} when ShouldFail ->
	    ct:fail(sasl_auth_should_have_failed);
	#sasl_success{} ->
            ejabberd_socket:reset_stream(?config(socket, Config)),
            send_text(Config,
                      io_lib:format(?STREAM_HEADER,
                                    [?config(server, Config)])),
            {xmlstreamstart, <<"stream:stream">>, Attrs} = recv(),
            <<"jabber:client">> = xml:get_attr_s(<<"xmlns">>, Attrs),
            <<"1.0">> = xml:get_attr_s(<<"version">>, Attrs),
	    StreamID = xml:get_attr_s(<<"id">>, Attrs),
	    NewConfig = set_opt(stream_id, StreamID, Config),
            #stream_features{sub_els = Fs} = recv(),
	    lists:foldl(
	      fun(#feature_sm{}, ConfigAcc) ->
		      set_opt(sm, true, ConfigAcc);
		 (#feature_csi{}, ConfigAcc) ->
		      set_opt(csi, true, ConfigAcc);
		 (_, ConfigAcc) ->
		      ConfigAcc
	      end, NewConfig, Fs);
        #sasl_challenge{text = ClientIn} ->
            {Response, SASL} = (?config(sasl, Config))(ClientIn),
            send(Config, #sasl_response{text = Response}),
            wait_auth_SASL_result(set_opt(sasl, SASL, Config), ShouldFail);
	#sasl_failure{} when ShouldFail ->
	    Config;
        #sasl_failure{} ->
            ct:fail(sasl_auth_failed)
    end.

re_register(Config) ->
    User = ?config(user, Config),
    Server = ?config(server, Config),
    Pass = ?config(password, Config),
    {atomic, ok} = ejabberd_auth:try_register(User, Server, Pass),
    ok.

match_failure(Received, [Match]) when is_list(Match)->
    ct:fail("Received input:~n~n~p~n~ndon't match expected patterns:~n~n~s", [Received, Match]);
match_failure(Received, Matches) ->
    ct:fail("Received input:~n~n~p~n~ndon't match expected patterns:~n~n~p", [Received, Matches]).

recv() ->
    receive
        {'$gen_event', {xmlstreamelement, El}} ->
            Pkt = xmpp_codec:decode(fix_ns(El)),
            ct:pal("recv: ~p ->~n~s", [El, xmpp_codec:pp(Pkt)]),
            Pkt;
        {'$gen_event', Event} ->
            Event
    end.

fix_ns(#xmlel{name = Tag, attrs = Attrs} = El)
  when Tag == <<"stream:features">>; Tag == <<"stream:error">> ->
    NewAttrs = [{<<"xmlns">>, <<"http://etherx.jabber.org/streams">>}
                |lists:keydelete(<<"xmlns">>, 1, Attrs)],
    El#xmlel{attrs = NewAttrs};
fix_ns(#xmlel{name = Tag, attrs = Attrs} = El)
  when Tag == <<"message">>; Tag == <<"iq">>; Tag == <<"presence">> ->
    NewAttrs = [{<<"xmlns">>, <<"jabber:client">>}
                |lists:keydelete(<<"xmlns">>, 1, Attrs)],
    El#xmlel{attrs = NewAttrs};
fix_ns(El) ->
    El.

send_text(Config, Text) ->
    ejabberd_socket:send(?config(socket, Config), Text).

send(State, Pkt) ->
    {NewID, NewPkt} = case Pkt of
                          #message{id = I} ->
                              ID = id(I),
                              {ID, Pkt#message{id = ID}};
                          #presence{id = I} ->
                              ID = id(I),
                              {ID, Pkt#presence{id = ID}};
                          #iq{id = I} ->
                              ID = id(I),
                              {ID, Pkt#iq{id = ID}};
                          _ ->
                              {undefined, Pkt}
                      end,
    El = xmpp_codec:encode(NewPkt),
    ct:pal("sent: ~p <-~n~s", [El, xmpp_codec:pp(NewPkt)]),
    ok = send_text(State, xml:element_to_binary(El)),
    NewID.

send_recv(State, El) ->
    ID = send(State, El),
    case El of
        #message{} ->
            #message{id = ID} = recv();
        #presence{} ->
            #presence{id = ID} = recv();
        #iq{} ->
            #iq{id = ID} = recv()
    end.

sasl_new(<<"PLAIN">>, User, Server, Password) ->
    {<<User/binary, $@, Server/binary, 0, User/binary, 0, Password/binary>>,
     fun (_) -> {error, <<"Invalid SASL challenge">>} end};
sasl_new(<<"EXTERNAL">>, User, Server, _Password) ->
    {<<User/binary, $@, Server/binary>>,
     fun (_) -> {error, <<"Invalid SASL challenge">>} end};
sasl_new(<<"DIGEST-MD5">>, User, Server, Password) ->
    {<<"">>,
     fun (ServerIn) ->
	     case cyrsasl_digest:parse(ServerIn) of
	       bad -> {error, <<"Invalid SASL challenge">>};
	       KeyVals ->
		   Nonce = xml:get_attr_s(<<"nonce">>, KeyVals),
		   CNonce = id(),
                   Realm = proplists:get_value(<<"realm">>, KeyVals, Server),
		   DigestURI = <<"xmpp/", Realm/binary>>,
		   NC = <<"00000001">>,
		   QOP = <<"auth">>,
		   AuthzId = <<"">>,
		   MyResponse = response(User, Password, Nonce, AuthzId,
					 Realm, CNonce, DigestURI, NC, QOP,
					 <<"AUTHENTICATE">>),
		   Resp = <<"username=\"", User/binary, "\",realm=\"",
			    Realm/binary, "\",nonce=\"", Nonce/binary,
			    "\",cnonce=\"", CNonce/binary, "\",nc=", NC/binary,
			    ",qop=", QOP/binary, ",digest-uri=\"",
			    DigestURI/binary, "\",response=\"",
			    MyResponse/binary, "\"">>,
		   {Resp,
		    fun (ServerIn2) ->
			    case cyrsasl_digest:parse(ServerIn2) of
			      bad -> {error, <<"Invalid SASL challenge">>};
			      _KeyVals2 ->
                                    {<<"">>,
                                     fun (_) ->
                                             {error,
                                              <<"Invalid SASL challenge">>}
                                     end}
			    end
		    end}
	     end
     end}.

hex(S) ->
    p1_sha:to_hexlist(S).

response(User, Passwd, Nonce, AuthzId, Realm, CNonce,
	 DigestURI, NC, QOP, A2Prefix) ->
    A1 = case AuthzId of
	   <<"">> ->
	       <<((erlang:md5(<<User/binary, ":", Realm/binary, ":",
				Passwd/binary>>)))/binary,
		 ":", Nonce/binary, ":", CNonce/binary>>;
	   _ ->
	       <<((erlang:md5(<<User/binary, ":", Realm/binary, ":",
				Passwd/binary>>)))/binary,
		 ":", Nonce/binary, ":", CNonce/binary, ":",
		 AuthzId/binary>>
	 end,
    A2 = case QOP of
	   <<"auth">> ->
	       <<A2Prefix/binary, ":", DigestURI/binary>>;
	   _ ->
	       <<A2Prefix/binary, ":", DigestURI/binary,
		 ":00000000000000000000000000000000">>
	 end,
    T = <<(hex((erlang:md5(A1))))/binary, ":", Nonce/binary,
	  ":", NC/binary, ":", CNonce/binary, ":", QOP/binary,
	  ":", (hex((erlang:md5(A2))))/binary>>,
    hex((erlang:md5(T))).

my_jid(Config) ->
    jlib:make_jid(?config(user, Config),
                  ?config(server, Config),
                  ?config(resource, Config)).

server_jid(Config) ->
    jlib:make_jid(<<>>, ?config(server, Config), <<>>).

pubsub_jid(Config) ->
    Server = ?config(server, Config),
    jlib:make_jid(<<>>, <<"pubsub.", Server/binary>>, <<>>).

proxy_jid(Config) ->
    Server = ?config(server, Config),
    jlib:make_jid(<<>>, <<"proxy.", Server/binary>>, <<>>).

muc_jid(Config) ->
    Server = ?config(server, Config),
    jlib:make_jid(<<>>, <<"conference.", Server/binary>>, <<>>).

muc_room_jid(Config) ->
    Server = ?config(server, Config),
    jlib:make_jid(<<"test">>, <<"conference.", Server/binary>>, <<>>).

id() ->
    id(undefined).

id(undefined) ->
    randoms:get_string();
id(ID) ->
    ID.

get_features(Config) ->
    get_features(Config, server_jid(Config)).

get_features(Config, To) ->
    #iq{type = result, sub_els = [#disco_info{features = Features}]} =
        send_recv(Config, #iq{type = get, sub_els = [#disco_info{}], to = To}),
    Features.

is_feature_advertised(Config, Feature) ->
    is_feature_advertised(Config, Feature, server_jid(Config)).

is_feature_advertised(Config, Feature, To) ->
    Features = get_features(Config, To),
    lists:member(Feature, Features).

set_opt(Opt, Val, Config) ->
    [{Opt, Val}|lists:keydelete(Opt, 1, Config)].

wait_for_master(Config) ->
    put_event(Config, slave_ready),
    master_ready = get_event(Config).

wait_for_slave(Config) ->
    put_event(Config, master_ready),
    slave_ready = get_event(Config).

make_iq_result(#iq{from = From} = IQ) ->
    IQ#iq{type = result, to = From, from = undefined, sub_els = []}.

%%%===================================================================
%%% Clients puts and gets events via this relay.
%%%===================================================================
start_event_relay() ->
    spawn(fun event_relay/0).

stop_event_relay(Config) ->
    Pid = ?config(event_relay, Config),
    exit(Pid, normal).

event_relay() ->
    event_relay([], []).

event_relay(Events, Subscribers) ->
    receive
        {subscribe, From} ->
            From ! {ok, self()},
            lists:foreach(
              fun(Event) -> From ! {event, Event, self()}
              end, Events),
            event_relay(Events, [From|Subscribers]);
        {put, Event, From} ->
            From ! {ok, self()},
            lists:foreach(
              fun(Pid) when Pid /= From ->
                      Pid ! {event, Event, self()};
                 (_) ->
                      ok
              end, Subscribers),
            event_relay([Event|Events], Subscribers)
    end.

subscribe_to_events(Config) ->
    Relay = ?config(event_relay, Config),
    Relay ! {subscribe, self()},
    receive
        {ok, Relay} ->
            ok
    end.

put_event(Config, Event) ->
    Relay = ?config(event_relay, Config),
    Relay ! {put, Event, self()},
    receive
        {ok, Relay} ->
            ok
    end.

get_event(Config) ->
    Relay = ?config(event_relay, Config),
    receive
        {event, Event, Relay} ->
            Event
    end.
