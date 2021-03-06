%% @author Kevin A. Smith <kevin@hypotheticalabs.com>
-module(kirby_segment).

-type ioerr() :: {error, atom()}.
-type raw_entry() :: <<_:32,_:_*8>>.
-type lock_tries() :: 0..5.
-record(seg, {dir=""       :: string(),
              lockfd       :: file:fd() | undefined,
              lockpath=""  :: string(),
              segfd        :: file:fd() | undefined,
              segpath=""   :: string()}).

-opaque seg() :: #seg{}.

-export_type([raw_entry/0,
              seg/0]).

-include("kirby.hrl").
-include("kirby_common.hrl").

-ifndef(TEST).
-export([open_for_write/1,
         open_for_read/2,
         write/2,
         read/3,
         close/1]).
-define(WRITE_OPTS, [raw, binary, write, append]).
-define(READ_OPTS,  [raw, binary, read]).
-define(LOCK_OPTS,  [raw, binary, exclusive, read, write]).
-define(LOCK_TRIES, 5).
-else.
-compile([export_all]).
%% Removed the 'raw' option because eunit plays fast
%% and loose with processes.
-define(WRITE_OPTS, [binary, write, append]).
-define(READ_OPTS,  [binary, read]).
-define(LOCK_OPTS,  [binary, exclusive, read, write]).
-define(LOCK_TRIES, 15).
-endif.

%% @doc Opens a segment for writing
-spec open_for_write(file:filename()) -> {ok, seg()} | ioerr().
open_for_write(BaseDir) ->
    open_for_write(BaseDir, next_segment(BaseDir), ?LOCK_TRIES).

%% @doc Opens a segment for reading
-spec open_for_read(file:filename(), string() | non_neg_integer()) -> {ok, seg()} | ioerr().
open_for_read(BaseDir, Idx) when is_integer(Idx) ->
    open_for_read(BaseDir, idx_to_str(Idx));
open_for_read(BaseDir, Idx) when is_list(Idx) ->
    Segment = seg_fname(BaseDir, Idx),
    case ?file:open(Segment, ?READ_OPTS) of
        {ok, Fd} ->
            {ok, #seg{segpath=Segment, segfd=Fd}};
        Error ->
            Error
    end.

%% @doc Closes a segment
-spec close(seg()) -> ok | ioerr().
close(#seg{lockfd=undefined, segfd=Fd}) ->
    ?file:close(Fd);
close(#seg{lockfd=LockFd, lockpath=LockPath, segfd=Fd, segpath=SegPath}) ->
    case flush(Fd) of
        ok ->
            case ?file:close(Fd) of
                ok ->
                    case ?file:close(LockFd) of
                        ok ->
                            case ?file:delete(LockPath) of
                                ok ->
                                    ok;
                                Error ->
                                    ?WARN("Dangling lock at ~s! (~p)~n", [LockPath, Error]),
                                    ok
                            end;
                        Error ->
                            ?WARN("File descriptor leak on lock ~s! (~p)~n", [LockPath, Error]),
                            ok
                    end;
                Error ->
                    ?ERR("File descriptor leak on segment ~s! (~p)~n", [SegPath, Error]),
                    Error
            end;
        Error ->
            ?WARN("Failed to sync data to disk on segment ~s! (~p)~n", [SegPath, Error]),
            ok
    end.

-spec write(seg(), binary()) -> {ok, integer(), non_neg_integer()} | {error, atom()}.
write(#seg{lockfd=undefined}, Data) when is_binary(Data) ->
    {error, read_only};
write(#seg{segfd=SegFd, segpath=SegPath, lockfd=LockFd}, Data) when LockFd /= undefined,
                                                                    is_binary(Data) ->
    case kirby_format:make_seg_entry(Data) of
        {ok, Entry} ->
            case ?file:position(SegFd, cur) of
                {ok, Start} ->
                    case ?file:write(SegFd, Entry) of
                        ok ->
                            case flush(SegFd) of
                                ok ->
                                    {ok, Start, size(Entry)};
                                Error ->
                                    ?WARN("Failed to sync data to disk on segment ~s! (~p)~n", [SegPath, Error]),
                                    {error, fsync}
                            end;
                        Error ->
                            abort_write(SegPath, Start, SegFd),
                            Error
                    end;
                Error ->
                    Error
            end;
        Error ->
            Error
    end.

-spec read(seg(), non_neg_integer(), non_neg_integer()) -> {ok, binary()} | {error, atom()} | eof.
read(#seg{segfd=SegFd, lockfd=undefined}, Start, Length) when Start >= 0,
                                                              Length >= 1 ->
    case ?file:pread(SegFd, Start, Length) of
        {ok, Raw} ->
            case kirby_format:parse_seg_entry(Raw) of
                {ok, _Checksum, Data} ->
                    {ok, Data};
                Error ->
                    Error
            end;
        Error ->
            Error
    end;
read(#seg{}, Start, Length) when is_integer(Start),
                                 is_integer(Length) ->
    {error, write_only}.



%% Internal functions
-spec next_segment(file:filename()) -> string().
next_segment(BaseDir) when is_binary(BaseDir);
                           is_list(BaseDir) ->
    case filelib:wildcard("segment-*", BaseDir) of
        [] ->
            "01";
        Segments ->
            {ok, Pattern} = re:compile("[0-9]+$", [dollar_endonly]),
            Segments1 = lists:reverse(lists:sort(Segments)),
            LastSegment = hd(Segments1),
            {match, [Idx]} = re:run(LastSegment, Pattern, [{capture, first, list}]),
            case is_locked(BaseDir, Idx) of
                false ->
                    Idx;
                true ->
                   idx_to_str(list_to_integer(Idx) + 1)
            end
    end.

-spec idx_to_str(integer()) -> string().
idx_to_str(Idx) when Idx < 10 ->
    "0" ++ integer_to_list(Idx);
idx_to_str(Idx) ->
    integer_to_list(Idx).

-spec lock_segment(file:filename(), string()) -> {ok, file:filename(), file:fd()} | ioerr().
lock_segment(BaseDir, Idx) ->
    LockFile = lock_fname(BaseDir, Idx),
    case ?file:open(LockFile, ?LOCK_OPTS) of
        {ok, Fd} ->
            case ?file:write(Fd, os:getpid()) of
                ok ->
                    {ok, LockFile, Fd};
                Error ->
                    ?file:close(Fd),
                    Error
            end;
        Error ->
            Error
    end.

-spec unlock_segment(file:filename(), file:fd()) -> ok | ioerr().
unlock_segment(LockFile, Fd) ->
    case ?file:close(Fd) of
        ok ->
            ?file:delete(LockFile);
        Error ->
            Error
    end.

-spec is_locked(file:filename(), string()) -> boolean().
is_locked(BaseDir, Idx) ->
    LockFile = lock_fname(BaseDir, Idx),
    filelib:is_dir(LockFile) orelse filelib:is_file(LockFile).

-spec open_for_write(file:filename(), string(), lock_tries()) -> {ok, seg()} | ioerr().
open_for_write(_BaseDir, _Idx, 0) ->
    {error, lock_failed};
open_for_write(BaseDir, Idx, Tries) ->
    case lock_segment(BaseDir, Idx) of
        {ok, LockFile, LockFd} ->
            SegFile = seg_fname(BaseDir, Idx),
            case ?file:open(SegFile, ?WRITE_OPTS) of
                {ok, Fd} ->
                    {ok, #seg{lockpath=LockFile, lockfd=LockFd,
                                    segpath=SegFile, segfd=Fd}};
                Error ->
                    unlock_segment(LockFile, LockFd),
                    Error
            end;
        {error, eexists} ->
            open_for_write(BaseDir, idx_to_str(list_to_integer(Idx) + 1), Tries - 1);
        Error ->
            Error
    end.

-ifdef(HAVE_FDATASYNC).
-spec flush(fd()) -> ok | ioerr().
flush(Fd) ->
    ?file:datasync(Fd).
-else.
flush(Fd) ->
    ?file:sync(Fd).
-endif.

abort_write(SegPath, Offset, Fd) ->
    case ?file:position(Fd, Offset) of
        {ok, _} ->
            case ?file:truncate(Fd) of
                ok ->
                    ok;
                Error ->
                    ?ERR("Error aborting write on segment ~s! (~p)~n", [SegPath, Error]),
                    Error
            end;
        Error ->
            ?ERR("Error aborting write on segment ~s! (~p)~n", [SegPath, Error]),
            Error
    end.

-spec lock_fname(file:filename(), string()) -> file:filename().
lock_fname(BaseDir, Idx) ->
    filename:join([BaseDir, "lock-" ++ Idx]).

-spec seg_fname(file:filename(), string()) -> file:filename().
seg_fname(BaseDir, Idx) ->
    filename:join([BaseDir, "segment-" ++ Idx]).
