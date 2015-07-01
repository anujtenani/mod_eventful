%%%------------------------------------------------------------------------
%%% File    : mod_eventful.erl
%%% Author  : Theo Cushion <theo@jivatechnology.com>
%%%         : Nicolas Alpi <nicolas.alpi@gmail.com>
%%% Purpose : Enables events triggered within ejabberd to generate HTTP
%%%           POST requests to an external service.
%%% Created : 29/03/2010
%%%------------------------------------------------------------------------

-module(mod_eventful).
-author('theo@jivatechnology.com').
-author('nicolas.alpi@gmail.com').

-behaviour(gen_server).
-behaviour(gen_mod).
-include("logger.hrl").

-define(PROCNAME, ?MODULE).

%% event handlers
-export([
    send_message/3,
    set_presence_log/4,
    unset_presence_log/4
    ]).

%% gen_server callbacks
-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
    ]).

%% gen_mod callbacks.
-export([
    start/2,
    stop/1,
    start_link/2]).

-include("ejabberd.hrl").
-include("jlib.hrl").

-record(state, {host, urls, auth_user, auth_password}).
-record(message, {from, to, type, subject, body, thread}).

%%====================================================================
%% Event handlers
%%====================================================================

send_message(From, To, P) ->
    case parse_message(From, To, P) of
        ignore -> 
            ok;
        Message ->
            post_results(message_hook, From#jid.lserver, Message),
            ok
    end.

element_to_string(Element) ->
  binary_to_list(xml:element_to_binary(Element)).


set_presence_log(User, Server, Resource, Presence) ->
    post_results(set_presence_hook, User, Server, Resource, lists:flatten(element_to_string(Presence))),
    case ejabberd_sm:get_user_resources(User,Server) of
        [_] ->        
            %%% First connection, so user has just come online
            post_results(online_hook, User, Server, Resource, lists:flatten(element_to_string(Presence)));
        _ ->
            false
    end,
    ok.

unset_presence_log(User, Server, Resource, Status) ->
    post_results(unset_presence_hook, User, Server, Resource, Status),
    case ejabberd_sm:get_user_resources(User,Server) of
        [] ->
            %%% No more connections, so user is totally offline
            %%% This occurs when a BOSH connection timesout
            post_results(offline_hook, User, Server, Resource, Status);
        [Resource] ->
            %%% We know that 'Resource' is no longer online, so can treat as if user is totally offline
            %%% This occurs when a user logs out
            post_results(offline_hook, User, Server, Resource, Status);
        _ ->
            false
    end,
    ok.
    
%%====================================================================
%% Internal functions
%%====================================================================

post_results(Event, Server, Message) ->
    Proc = gen_mod:get_module_proc(Server, ?PROCNAME),
    gen_server:call(Proc, {post_results, Event, Message}).
post_results(Event, User, Server, Resource, Message) ->
    Proc = gen_mod:get_module_proc(Server, ?PROCNAME),
    gen_server:call(Proc, {post_results, Event, User, Server, Resource, Message}).

url_for(Event, Urls) ->
    case lists:keysearch(Event,1,Urls) of
        {value,{_,Result}} -> Url = Result;
        _                  -> Url = undefined
    end,
    Url.
    
% parse a message and return the body string if successful
% return ignore if the message should not be stored
parse_message(From, To, {xmlel, <<"message">>, _, _} = Packet) ->
    Type    = xml:get_tag_attr_s(<<"type">>, Packet),
    Subject = get_tag_from(<<"subject">>, Packet),
    Body    = get_tag_from(<<"body">>, Packet),
    Thread  = get_tag_from(<<"thread">>, Packet),
    #message{from = jlib:jid_to_string(From), to = jlib:jid_to_string(To), type = Type, subject = Subject, body = Body, thread = Thread};
parse_message(_From, _To, _) -> ignore.

get_tag_from(Tag, Packet) ->
    case xml:get_subtag(Packet, Tag) of
        false -> 
            "";
        Xml   ->
            xml:get_tag_cdata(Xml)
    end.
    
send_data(Event, Data, State) -> 
    Urls         = State#state.urls,
    Url          = url_for(Event, Urls),
    AuthUser     = State#state.auth_user,
    AuthPassword = State#state.auth_password,
    case is_list(AuthUser) andalso is_list(AuthPassword) of
        true  -> 
            UserPassword = base64:encode_to_string(AuthUser ++ ":" ++ AuthPassword),
            Headers      = [{"Authorization", "Basic " ++ UserPassword}];
        false ->
            Headers = []
    end,
    case is_binary(Url) of
        true ->
            ?INFO_MSG("Triggered post from event: ~p, Data: ~p",[Event, Data]),
            httpc:request(
                post, {
                    binary_to_list(Url),
                    Headers,
                    "application/x-www-form-urlencoded", Data
                },
                [],
                [{sync, false},{stream, self}]
            );
        false ->
            false
    end.
    
%%====================================================================
%% gen_server callbacks
%%====================================================================
%%--------------------------------------------------------------------
%% Function: init(Args) -> {ok, State} |
%%                         {ok, State, Timeout} |
%%                         ignore               |
%%                         {stop, Reason}
%% Description: Initiates the server
%%--------------------------------------------------------------------
init([Host, _Opts]) ->
    inets:start(),
    ejabberd_hooks:add(user_send_packet,    Host, ?MODULE, send_message,       50),
    ejabberd_hooks:add(set_presence_hook,   Host, ?MODULE, set_presence_log,   50),
    ejabberd_hooks:add(unset_presence_hook, Host, ?MODULE, unset_presence_log, 50),
    Urls         = gen_mod:get_module_opt(global, ?MODULE, url, fun id/1, []),
    AuthUser     = gen_mod:get_module_opt(global, ?MODULE, user,  fun id/1,    undefined),
    AuthPassword = gen_mod:get_module_opt(global, ?MODULE, password,  fun id/1,undefined),
    {ok, #state{host = Host, urls = Urls, auth_user = AuthUser, auth_password = AuthPassword}}.

id(T) -> T.

%%--------------------------------------------------------------------
%% Function: %% handle_call(Request, From, State) -> {reply, Reply, State} |
%%                                      {reply, Reply, State, Timeout} |
%%                                      {noreply, State} |
%%                                      {noreply, State, Timeout} |
%%                                      {stop, Reason, Reply, State} |
%%                                      {stop, Reason, State}
%% Description: Handling call messages
%%--------------------------------------------------------------------
handle_call({post_results, message_hook, Message}, _From, State) ->
    Data = "from="     ++ url_encode(Message#message.from)++
           "&to="      ++ url_encode(Message#message.to)++
           "&type="    ++ url_encode(Message#message.type)++ 
           "&subject=" ++ url_encode(Message#message.subject)++
           "&body="    ++ url_encode(Message#message.body)++
           "&thread="  ++ url_encode(Message#message.thread),
    send_data(message_hook, Data, State),
    {reply, ok, State};
handle_call({post_results, Event, User, Server, Resource, Message}, _From, State) ->
    Data = "user="      ++ url_encode(User)++
           "&server="   ++ url_encode(Server)++
           "&resource=" ++ url_encode(Resource)++ 
           "&message="  ++ url_encode(Message),
    send_data(Event, Data, State),
    {reply, ok, State};
handle_call(stop, _From, State) ->
    {stop, normal, ok, State}.

url_encode(List) when is_list(List) ->
  url_encode(list_to_binary(List));
url_encode(Bin) when is_binary(Bin) ->
  binary_to_list(ejabberd_http:url_encode(Bin)).
    
%%--------------------------------------------------------------------
%% Function: handle_cast(Msg, State) -> {noreply, State} |
%%                                      {noreply, State, Timeout} |
%%                                      {stop, Reason, State}
%% Description: Handling cast messages
%%--------------------------------------------------------------------
handle_cast(_Msg, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% Function: handle_info(Info, State) -> {noreply, State} |
%%                                       {noreply, State, Timeout} |
%%                                       {stop, Reason, State}
%% Description: Handling all non call/cast messages
%%--------------------------------------------------------------------
handle_info({http, {RequestId, stream_start, Headers}}, State) ->
    ?DEBUG("http stream_start RequestId: ~p, Headers: ~p",[RequestId, Headers]),
    {noreply, State};
handle_info({http, {RequestId, stream, BinBodyPart}}, State) ->
    ?DEBUG("http stream RequestId: ~p, BinBodyPart: ~p",[RequestId, BinBodyPart]),
    {noreply, State};
handle_info({http, {RequestId, stream_end, Headers}}, State) ->
    ?DEBUG("http stream_end RequestId: ~p, Headers: ~p",[RequestId, Headers]),
    {noreply, State};
handle_info(_Info, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% Function: terminate(Reason, State) -> void()
%% Description: This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any necessary
%% cleaning up. When it returns, the gen_server terminates with Reason.
%% The return value is ignored.
%%--------------------------------------------------------------------
terminate(_Reason, State) ->
    Host = State#state.host,
    ejabberd_hooks:delete(user_send_packet,    Host, ?MODULE, send_message,       50),
    ejabberd_hooks:delete(set_presence_hook,   Host, ?MODULE, set_presence_log,   50),
    ejabberd_hooks:delete(unset_presence_hook, Host, ?MODULE, unset_presence_log, 50),
    ok.
    
%%--------------------------------------------------------------------
%% Func: code_change(OldVsn, State, Extra) -> {ok, NewState}
%% Description: Convert process state when code is changed
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%====================================================================
%% API
%%====================================================================
%%--------------------------------------------------------------------
%% Function: start_link() -> {ok,Pid} | ignore | {error,Error}
%% Description: Starts the server
%%--------------------------------------------------------------------
start_link(Host, Opts) ->
    Proc = gen_mod:get_module_proc(Host, ?PROCNAME),
    gen_server:start_link({local, Proc}, ?MODULE, [Host, Opts], []).

%%====================================================================
%% gen_mod callbacks
%%====================================================================

start(Host, Opts) ->
    Proc = gen_mod:get_module_proc(Host, ?PROCNAME),
    ChildSpec =	{
        Proc,
	    {?MODULE, start_link, [Host, Opts]},
	    transient,
	    1000,
	    worker,
	    [?MODULE]},
    supervisor:start_child(ejabberd_sup, ChildSpec).
    
stop(Host) ->
    Proc = gen_mod:get_module_proc(Host, ?PROCNAME),
    gen_server:call(Proc, stop),
    supervisor:delete_child(ejabberd_sup, Proc).
