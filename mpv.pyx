# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

"""pympv - Python wrapper for libmpv

libmpv is a client library for the media player mpv

For more info see: https://github.com/mpv-player/mpv/blob/master/libmpv/client.h
"""

import sys
import weakref
from threading import Thread, Semaphore
from _thread import exit as thread_exit
from enum import Enum, IntEnum
import locale
locale.setlocale(locale.LC_NUMERIC,'C')
try:
    from queue import Queue, Empty, Full
except ImportError:
    from Queue import Queue, Empty, Full
from collections import UserDict
from libc.stdlib cimport malloc, free
from libc.string cimport strcpy

from client cimport *
from opengl_cb cimport *
from stream_cb cimport *
from talloc cimport *

cimport cython

__version__ = "0.3.0"
__author__ = "Andre D"

_REQUIRED_CAPI_MAJOR = 1
_MIN_CAPI_MINOR = 9

cdef unsigned long _CAPI_VERSION
with nogil:
    _CAPI_VERSION = mpv_client_api_version()

_CAPI_MAJOR = _CAPI_VERSION >> 16
_CAPI_MINOR = _CAPI_VERSION & 0xFFFF

if _CAPI_MAJOR != _REQUIRED_CAPI_MAJOR or _CAPI_MINOR < _MIN_CAPI_MINOR:
    raise ImportError(
        "libmpv version is incorrect. Required %d.%d got %d.%d." %
            (_REQUIRED_CAPI_MAJOR, _MIN_CAPI_MINOR, _CAPI_MAJOR, _CAPI_MINOR)
    )
cdef extern from "Python.h":
    void PyEval_InitThreads()

cdef bint   _is_py3 = sys.version_info >= (3,)
cdef object _strdec_err = "surrogateescape" if _is_py3 else "strict"
# mpv -> Python
cdef _strdec(s):
    try:    return s.decode("utf-8", _strdec_err)
    # In python2, bail to bytes on failure
    except: return bytes(s)
# Python -> mpv
cdef _strenc(s):
    try:    return s.encode("utf-8", _strdec_err)
        # In python2, assume bytes and walk right through
    except: return s

PyEval_InitThreads()

class Error(IntEnum):
    """Set of known error codes from MpvError and Event responses.

    Mostly wraps the enum mpv_error.
    Values might not always be integers in the future.
    You should handle the possibility that error codes may not be any of these values.
    """
    success = MPV_ERROR_SUCCESS
    queue_full = MPV_ERROR_EVENT_QUEUE_FULL
    nomem = MPV_ERROR_NOMEM
    uninitialized = MPV_ERROR_UNINITIALIZED
    invalid_parameter = MPV_ERROR_INVALID_PARAMETER
    not_found = MPV_ERROR_OPTION_NOT_FOUND
    option_not_found = MPV_ERROR_OPTION_NOT_FOUND
    option_format = MPV_ERROR_OPTION_FORMAT
    option_error = MPV_ERROR_OPTION_ERROR
    property_not_found = MPV_ERROR_PROPERTY_NOT_FOUND
    property_format = MPV_ERROR_PROPERTY_FORMAT
    property_unavailable = MPV_ERROR_PROPERTY_UNAVAILABLE
    property_error = MPV_ERROR_PROPERTY_ERROR
    command_error = MPV_ERROR_COMMAND
    loading_failed = MPV_ERROR_LOADING_FAILED
    ao_init_failed = MPV_ERROR_AO_INIT_FAILED
    vo_init_failed = MPV_ERROR_VO_INIT_FAILED
    nothing_to_play = MPV_ERROR_NOTHING_TO_PLAY
    unknown_format = MPV_ERROR_UNKNOWN_FORMAT
    unsupported = MPV_ERROR_UNSUPPORTED
    not_implemented = MPV_ERROR_NOT_IMPLEMENTED

    def __init__(self, int val):
        cdef const char* err_c
        with nogil:err_c = mpv_error_string(val)
        self.error_str = _strdec(err_c)

class EventType(IntEnum):
    """Set of known values for Event ids.

    Mostly wraps the enum mpv_event_id.
    Values might not always be integers in the future.
    You should handle the possibility that event ids may not be any of these values.
    """
    none = MPV_EVENT_NONE
    shutdown = MPV_EVENT_SHUTDOWN
    log_message = MPV_EVENT_LOG_MESSAGE
    get_property_reply = MPV_EVENT_GET_PROPERTY_REPLY
    set_property_reply = MPV_EVENT_SET_PROPERTY_REPLY
    command_reply = MPV_EVENT_COMMAND_REPLY
    start_file = MPV_EVENT_START_FILE
    end_file = MPV_EVENT_END_FILE
    file_loaded = MPV_EVENT_FILE_LOADED
    tracks_changed = MPV_EVENT_TRACKS_CHANGED
    tracks_switched = MPV_EVENT_TRACK_SWITCHED
    idle = MPV_EVENT_IDLE
    pause = MPV_EVENT_PAUSE
    unpause = MPV_EVENT_UNPAUSE
    tick = MPV_EVENT_TICK
    script_input_dispatch = MPV_EVENT_SCRIPT_INPUT_DISPATCH
    client_message = MPV_EVENT_CLIENT_MESSAGE
    video_reconfig = MPV_EVENT_VIDEO_RECONFIG
    audio_reconfig = MPV_EVENT_AUDIO_RECONFIG
    metadata_update = MPV_EVENT_METADATA_UPDATE
    seek = MPV_EVENT_SEEK
    playback_restart = MPV_EVENT_PLAYBACK_RESTART
    property_change = MPV_EVENT_PROPERTY_CHANGE
    chapter_change = MPV_EVENT_CHAPTER_CHANGE
    def __init__(self, mpv_event_id val):
        cdef const char* err_c
        with nogil:err_c = mpv_event_name(val)
        self.event_name = _strdec(err_c)

class LogLevels(IntEnum):
    no = MPV_LOG_LEVEL_NONE
    fatal = MPV_LOG_LEVEL_FATAL
    error = MPV_LOG_LEVEL_ERROR
    warn = MPV_LOG_LEVEL_WARN
    info = MPV_LOG_LEVEL_INFO
    v = MPV_LOG_LEVEL_V
    debug = MPV_LOG_LEVEL_DEBUG
    trace = MPV_LOG_LEVEL_TRACE

class EOFReasons(IntEnum):
    """Known possible values for EndOfFileReached reason.

    You should handle the possibility that the reason may not be any of these values.
    """
    eof = MPV_END_FILE_REASON_EOF
    aborted = MPV_END_FILE_REASON_STOP
    quit = MPV_END_FILE_REASON_QUIT
    error = MPV_END_FILE_REASON_ERROR

@cython.freelist(64)
cdef class EndOfFileReached:
    """Data field for MPV_EVENT_END_FILE events

    Wraps: mpv_event_end_file
    """
    cdef object __weakref__
    cdef public object reason
    cdef public object error
    @staticmethod
    cdef EndOfFileReached create(mpv_event_end_file* eof):
        return EndOfFileReached()._init(eof)

    cdef _init(self, mpv_event_end_file* eof):
        self.reason = eof.reason
        self.error  = eof.error
        return self

@cython.freelist(256)
cdef class InputDispatch:
    """Data field for MPV_EVENT_SCRIPT_INPUT_DISPATCH events.

    Wraps: mpv_event_script_input_dispatch
    """
    cdef object __weakref__
    cdef public object arg0
    cdef public object type
    @staticmethod
    cdef InputDispatch create(mpv_event_script_input_dispatch* evt):
        return InputDispatch()._init(evt)

    cdef _init(self, mpv_event_script_input_dispatch* input):
        self.arg0 = input.arg0
        self.type = _strdec(input.type)
        return self

@cython.freelist(256)
cdef class LogMessage:
    """Data field for MPV_EVENT_LOG_MESSAGE events.

    Wraps: mpv_event_log_message
    """
    cdef object __weakref__
    cdef public str prefix
    cdef public str level
    cdef public str text
    cdef public object log_level
    cdef _init(self, mpv_event_log_message* msg):
        self.level  = _strdec(msg.level)
        self.prefix = _strdec(msg.prefix)
        self.text   = _strdec(msg.text)
        self.log_level = LogLevels(msg.log_level)
        return self

    @staticmethod
    cdef LogMessage create(mpv_event_log_message *msg):
        return LogMessage()._init(msg)

cdef _convert_node_value(mpv_node node):
    if   node.format == MPV_FORMAT_STRING:       return _strdec(node.u.string)
    elif node.format == MPV_FORMAT_FLAG:         return not not int(node.u.flag)
    elif node.format == MPV_FORMAT_INT64:        return int(node.u.int64)
    elif node.format == MPV_FORMAT_DOUBLE:       return float(node.u.double_)
    elif node.format == MPV_FORMAT_NODE_MAP:     return _convert_value(node.u.list, node.format)
    elif node.format == MPV_FORMAT_NODE_ARRAY:   return _convert_value(node.u.list, node.format)
    else:                                        return None

cdef _convert_value(void* data, mpv_format fmt):
    cdef mpv_node node
    cdef mpv_node_list nodelist
    if fmt == MPV_FORMAT_NODE:
        node = (<mpv_node*>data)[0]
        return _convert_node_value(node)
    elif fmt == MPV_FORMAT_NODE_ARRAY:
        nodelist = (<mpv_node_list*>data)[0]
        return [_convert_node_value(nodelist.values[i]) for i in range(nodelist.num)]
    elif fmt == MPV_FORMAT_NODE_MAP:
        nodelist = (<mpv_node_list*>data)[0]
        return {_strdec(nodelist.keys[i]):
                _convert_node_value(nodelist.values[i]) for i in range(nodelist.num)}
    elif fmt == MPV_FORMAT_STRING:   return _strdec(((<char**>data)[0]))
    elif fmt == MPV_FORMAT_FLAG:     return not not (<uint64_t*>data)[0]
    elif fmt == MPV_FORMAT_INT64:    return int((<uint64_t*>data)[0])
    elif fmt == MPV_FORMAT_DOUBLE:   return float((<double*>data)[0])
    else:                            return None

@cython.freelist(256)
cdef class Property:
    """Data field for MPV_EVENT_PROPERTY_CHANGE and MPV_EVENT_GET_PROPERTY_REPLY.

    Wraps: mpv_event_property
    """
    cdef object __weakref__
    cdef public str name
    cdef public object data
    cdef _init(self, mpv_event_property* prop):
        self.name = _strdec(prop.name)
        self.data = _convert_value(prop.data, prop.format)
        return self

    @staticmethod
    cdef Property create(mpv_event_property* prop):
        return Property()._init(prop)

@cython.freelist(256)
cdef class Event:
    """Wraps: mpv_event"""
    cdef object __weakref__
    cdef public object id
    cdef public object error
    cdef public object data
    cdef public object reply_userdata

    @property
    def error_str(self):
        """mpv_error_string of the error proeprty"""
        return self.error.error_str

    cdef _data(self, mpv_event* event):
        cdef void* data = event.data
        cdef mpv_event_client_message* climsg
        if   self.id == MPV_EVENT_GET_PROPERTY_REPLY:   return Property.create(<mpv_event_property*>data)
        elif self.id == MPV_EVENT_PROPERTY_CHANGE:      return Property.create(<mpv_event_property*>data)
        elif self.id == MPV_EVENT_LOG_MESSAGE:          return LogMessage.create(<mpv_event_log_message*>data)
        elif self.id == MPV_EVENT_SCRIPT_INPUT_DISPATCH:return InputDispatch.create(<mpv_event_script_input_dispatch*>data)
        elif self.id == MPV_EVENT_CLIENT_MESSAGE:
            climsg = <mpv_event_client_message*>data
            return [_strdec(<char*>(climsg.args[i])) for i in range(climsg.num_args)]
        elif self.id == MPV_EVENT_END_FILE:
            return EndOfFileReached.create(<mpv_event_end_file*>data)

    @property
    def name(self):
        """mpv_event_name of the event id"""
        return self.id.event_name

    @staticmethod
    cdef Event create(mpv_event* event, ctx):
        return Event()._init(event,ctx)

    cdef _init(self, mpv_event* event, ctx):
        cdef uint64_t ctxid = <uint64_t>id(ctx)
        self.id = EventType(event.event_id)
        self.data = self._data(event)
        userdata = _reply_userdatas[ctxid].get(event.reply_userdata, None)
        if userdata is not None:
            if self.id != MPV_EVENT_PROPERTY_CHANGE:
                userdata.decref()
            userdata = userdata.data
        self.reply_userdata = userdata
        self.error = Error(event.error)
        return self

def _errors(fn):
    def wrapped(*k, **kw):
        v = fn(*k, **kw)
        if v < 0:
            raise MPVError(v)
    return wrapped

class MPVError(Exception):
    __cache__ = {}
    code = None
    message = None
    def __init__(self, e):
        cdef int e_i
        cdef const char* e_c
        if isinstance(e,Error):
            self.code = e
        elif isinstance(e,(int,)):
            e_i = e
            self.code = Error(e_i)
        if isinstance(self.code,Error):
            e = self.code.error_str
        elif not isinstance(e,str):
            e = str(e)
        super().__init__(e)

cdef object _callbacks        = weakref.WeakValueDictionary()
cdef object _reply_userdatas = weakref.WeakValueDictionary()

#@cython.freelist(256)
cdef class _ReplyUserData:
    cdef object __weakref__
    cdef public int    refcnt
    cdef public object wref
    cdef public object data
    def __cinit__(self, data, wref = None):
        self.refcnt = 0
        self.data = data
        if wref is not None:
            self.wref = weakref.ref(wref)
        else:
            self.wref = None

    @property
    def observed(self):
        return self.refcnt> 0

    @observed.setter
    def observed(self, bint v):
        if v: self.incref()
        else: self.decref()

    def incref(self):
        self.refcnt+= 1

    def decref(self):
        cdef uint64_t data_id
        self.refcnt -= 1
        ref = self.wref()
        if self.refcnt <= 0 and ref:
            data_id = <uint64_t>hash(self.data)
            if data_id in ref:
                del ref[data_id]


cdef class ContextProxy:
    cdef object __weakref__
    cdef object __context__
    def __init__(self, Context ctx):
        self.__context__ = weakref.ref(ctx)

    @property
    def context(self):
        return self.__context__()

    def __nonzero__(self):
        return self.context is not None

cdef class OptionInfoProxy(ContextProxy):
    def __dir__(self):
        context = self.context
        if context:
            return context.options

    def __len__(self):
        return len(dir(self))

    def __getattr__(self, key):
        context = self.context
        if context:
            return context.get_property('option-info/{}'.format(key.replace('_','-')))
        raise ValueError("attempt to access invalid option info proxy.")

cdef class OptionsProxy(ContextProxy):
    def __dir__(self):
        context = self.context
        if context:
            return context.options

    def __len__(self):
        return len(dir(self))

    def __getattr__(self, key):
        context = self.context
        if context:
            return context.get_property('options/{}'.format(context.option_name(key)))
        raise ValueError("attempt to access invalid option info proxy.")

    def __setattr__(self, key, val):
        context = self.context
        if context:
            context.set_option(context.option_name(key), val)

cdef mpv_node empty_node():
    cdef mpv_node ret
    ret.format = MPV_FORMAT_NONE
    ret.u.string = NULL
    return ret

cdef class Context(object):
    """Base class wrapping a context to interact with mpv.

    Assume all calls can raise MPVError.

    Wraps: mpv_create, mpv_destroy and all mpv_handle related calls
    """
    cdef object __weakref__
    cdef object reply_userdata
    cdef mpv_handle *_ctx
    cdef readonly object cb_context
    cdef readonly object callback
    cdef readonly object callbackthread
    cdef readonly set properties
    cdef readonly set options
    cdef dict _props
    cdef dict _opts

    @property
    def name(self):
        """Unique name for every context created.

        Wraps: mpv_client_name
        """
        cdef const char* name
        with nogil:
            name = mpv_client_name(self._ctx)
        return _strdec(name)

    @property
    def time(self):
        """Internal mpv client time.

        Has an arbitrary start offset, but will never wrap or go backwards.

        Wraps: mpv_get_time_us
        """
        cdef int64_t time
        with nogil:
            time = mpv_get_time_us(self._ctx)
        return time

    def __dir__(self):
        return [*set(map(lambda x:x.replace('-','_'),self.properties|self.options)),*super().__dir__()]

    def request_event(self, event, enable):
        """Enable or disable a given event.

        Arguments:
        event - See EventType
        enable - True to enable, False to disable

        Wraps: mpv_request_event
        """
        cdef int enable_i = 1 if enable else 0
        cdef int err
        cdef mpv_event_id event_id = event
        with nogil:
            err = mpv_request_event(self._ctx, event_id, enable_i)
        if err < 0:
            raise MPVError(err)
        return Error(err);

    def set_log_level(self, loglevel):
        """Wraps: mpv_request_log_messages"""
        loglevel = _strenc(loglevel)
        cdef const char* loglevel_c = loglevel
        cdef int err
        with nogil:
            err = mpv_request_log_messages(self._ctx, loglevel_c)
        if err < 0:
            raise MPVError(err)
        return Error(err);

    def load_config(self, filename):
        """Wraps: mpv_load_config_file"""
        filename = _strenc(filename)
        cdef const char* _filename = filename
        cdef int err
        with nogil:
            err = mpv_load_config_file(self._ctx, _filename)
        if err < 0:
            raise MPVError(err)
        return Error(err);
    @staticmethod
    cdef mpv_format _format_for(value):
        if   isinstance(value, str):            return MPV_FORMAT_STRING
        elif isinstance(value, bool):           return MPV_FORMAT_FLAG
        elif isinstance(value, int):            return MPV_FORMAT_INT64
        elif isinstance(value, float):          return MPV_FORMAT_DOUBLE
        elif isinstance(value, (tuple, list)):  return MPV_FORMAT_NODE_ARRAY
        elif isinstance(value, dict):           return MPV_FORMAT_NODE_MAP
        else:                                   return MPV_FORMAT_NONE
    @classmethod
    cdef mpv_node_list* _prep_node_list(cls, values, void *ctx = NULL):
        cdef mpv_node node = empty_node()
        cdef mpv_format fmt = MPV_FORMAT_NONE
        cdef mpv_node_list* node_list = <mpv_node_list*>talloc_zero_size(ctx,sizeof(mpv_node_list))
        node_list.num    = len(values)
        if node_list.num:
            node_list.values = <mpv_node*>talloc_array_size(node_list, sizeof(mpv_node),node_list.num)
            for i, value in enumerate(values):
                fmt                 = cls._format_for(value)
                node                = cls._prep_native_value(value, fmt, node_list)
                node_list.values[i] = node
        return node_list

    @classmethod
    cdef mpv_node_list* _prep_node_map(cls, _map, void *ctx = NULL):
        cdef char* ckey           = NULL
        cdef mpv_node_list* _list = cls._prep_node_list(_map.values(), ctx)
        keys = _map.keys()
        if not len(keys):
            return _list
        _list.keys = <char**>talloc_array_size(_list, sizeof(char*),_list.num)
        for i, key in enumerate(keys):
            key = _strenc(key)
            ckey = key
            _list.keys[i] = <char*>talloc_memdup(_list, ckey, len(key) + 1)
        return _list

    @classmethod
    cdef mpv_node _prep_native_value(cls, value, mpv_format fmt, void *ctx = NULL):
        cdef mpv_node node = empty_node()
        node.format = fmt
        cdef const char *_value = NULL
        if fmt = MPV_FORMAT_STRING:
            value = _strenc(value)
            _value = value
            node.u.string = <char*>talloc_memdup(ctx, _value, len(value) + 1)
        elif fmt == MPV_FORMAT_FLAG:         node.u.flag = 1 if value else 0
        elif fmt == MPV_FORMAT_INT64:        node.u.int64 = value
        elif fmt == MPV_FORMAT_DOUBLE:       node.u.double_ = value
        elif fmt == MPV_FORMAT_NODE_ARRAY:   node.u.list = cls._prep_node_list(value, ctx)
        elif fmt == MPV_FORMAT_NODE_MAP:     node.u.list = cls._prep_node_map(value, ctx)
        else:                                node.format = MPV_FORMAT_NONE
        return node

    @classmethod
    cdef _free_native_value(cls, mpv_node node):
        if node.format in (MPV_FORMAT_NODE_ARRAY, MPV_FORMAT_NODE_MAP, MPV_FORMAT_STRING):
            talloc_free(node.u.list)
        node.u.list = NULL
#            for i in range(node.u.list.num):
#                cls._free_native_value(node.u.list.values[i])
#            talloc_free(node.u.list.values)
#            node.u.list.values = NULL
#            if node.format == MPV_FORMAT_NODE_MAP:
#                for i in range(node.u.list.num):
#                    talloc_free(node.u.list.keys[i])
#                talloc_free(node.u.list.keys)
#                node.u.list.keys = NULL
#            talloc_free(node.u.list)
#            node.u.list = NULL
#        elif node.format == MPV_FORMAT_STRING:
#            talloc_free(node.u.string)
##            free(node.u.string)
#            node.u.string = NULL

    def command(self, *cmdlist, _async=False, data=None):
        """Send a command to mpv.

        Non-async success returns the command's response data, otherwise None

        Arguments:
        Accepts parameters as args

        Keyword Arguments:
        async: True will return right away, status comes in as MPV_EVENT_COMMAND_REPLY
        data: Only valid if async, gets sent back as reply_userdata in the Event

        Wraps: mpv_command_node and mpv_command_node_async
        """
        assert self._ctx
        cdef mpv_node node = self._prep_native_value(cmdlist, self._format_for(cmdlist))
        cdef mpv_node noderesult = empty_node()
        cdef int err
        cdef uint64_t data_id
        result = None
        try:
            data_id = id(data)
            if not _async:
                with nogil: err = mpv_command_node(self._ctx, &node, &noderesult)
                try:        result = _convert_node_value(noderesult) if err >= 0 else None
                finally:
                    with nogil:
                        mpv_free_node_contents(&noderesult)
            else:
                userdatas = self.reply_userdata.get(data_id, None)
                if userdatas is None:
                    _reply_userdatas[data_id] = userdatas = _ReplyUserData(data, self.reply_userdata)
                userdatas.incref()
                with nogil:
                    err = mpv_command_node_async(self._ctx, data_id, &node)
        finally:
            self._free_native_value(node)
        if err < 0:
            raise MPVError(err)
        return result

    def get_property_async(self, prop, data=None):
        """Gets the value of a property asynchronously.

        Arguments:
        prop: Property to get the value of.

        Keyword arguments:
        data: Value to be passed into the reply_userdata of the response event.
        Wraps: mpv_get_property_async"""
        assert self._ctx
        prop = _strenc(prop)
        cdef uint64_t id_data = <uint64_t>hash(data)
        userdatas = self.reply_userdata.get(id_data, None)
        if userdatas is None:
            self.reply_userdata[id_data] = userdatas = _ReplyUserData(data,self.reply_userdata)
        userdatas.incref()
        cdef const char* prop_c = prop
        with nogil:
            err = mpv_get_property_async(
                self._ctx,
                id_data,
                prop_c,
                MPV_FORMAT_NODE,
            )
        if err < 0:
            raise MPVError(err)
#        return Error(err)

    def try_get_property_async(self, prop, data=None, default=None):
        try:
            return self.get_property_async(prop, data=data)
        except MPVError:
            return default

    def try_get_property(self, prop, default=None):
        try:
            return self.get_property(prop)
        except MPVError:
            return default

    def get_property(self, prop):
        """Wraps: mpv_get_property"""
        assert self._ctx
        cdef mpv_node result
        result.format   = MPV_FORMAT_NONE
        result.u.string = NULL
        prop = _strenc(prop)
        cdef const char* prop_c = prop
        cdef int err
        with nogil:
            err = mpv_get_property(
                        self._ctx,
                        prop_c,
                        MPV_FORMAT_NODE,
                        &result,
                    )
        if err < 0:
            raise MPVError(err)
        try:
            v = _convert_node_value(result)
        finally:
            with nogil:
                mpv_free_node_contents(&result)
        return v

    @_errors
    def set_property(self, prop, value=True, _async=False, data=None):
        """Wraps: mpv_set_property and mpv_set_property_async"""
        assert self._ctx
        prop = _strenc(prop)
        cdef mpv_format fmt = self._format_for(value)
        cdef mpv_node v = self._prep_native_value(value, fmt )
        cdef int err
        cdef uint64_t data_id
        cdef const char* prop_c
        try:
            prop_c = prop
            if not _async:
                with nogil:
                    err = mpv_set_property(
                        self._ctx,
                        prop_c,
                        MPV_FORMAT_NODE,
                        &v
                    )
                return Error(err)
            data_id = <uint64_t>hash(data)
            userdatas = self.reply_userdata.get(data_id, None)
            if userdatas is None:
                self.reply_userdata[data_id] = userdatas = _ReplyUserData(data, self.reply_userdata)
            userdatas.incref()
            with nogil:
                err = mpv_set_property_async(
                    self._ctx,
                    data_id,
                    prop_c,
                    MPV_FORMAT_NODE,
                    &v
                )
        finally:
            self._free_native_value(v)
        return Error(err)

    def __getattr__(self,oname):
        name = oname.replace('_','-')
        if name in self._props:
            return self.get_property(self._props[name])
        elif name in self._opts:
            return self.get_property(self._opts[name])
        else:
            try:
                ret = self.get_property(name)
                self._props[name] = name
                return ret
            except MPVError as e:
                if e.code not in ( MPV_ERROR_OPTION_NOT_FOUND,
                                   MPV_ERROR_PROPERTY_NOT_FOUND ):
                    raise
                    #raise AttributeError(*e.args)
            try:
                better = self.get_property("option-info/{}/name".format(name))

                ret = self.get_property('options/'+better)
                self._opts[name] = 'options/'+better
                return ret
            except MPVError as e:
                if e.code not in ( MPV_ERROR_OPTION_NOT_FOUND,
                                   MPV_ERROR_PROPERTY_NOT_FOUND ):
                    raise
#                    raise AttributeError(*e.args)
        raise AttributeError

    def __setattr__(self,name,value):
        name = name.replace('_','-')
        if name in self._props:
            self.set_property(self._props[name],value)
        elif name in self._opts:
            self.set_property(self._opts[name],value)
        else:
            try:
                self.set_property(name,value)
                self._props[name] = name
                return
            except MPVError as e:
                if e.code != Error.not_found:
                    raise AttributeError(*e.args)
            try:
                self.set_property('options/'+name,value)
                self._opts[name]  = 'options/'+name
                return
            except MPVError as e:
                if e.code != Error.not_found:
                    raise AttributeError(*e.args)
            raise AttributeError
        return

    def set_option(self, prop, value=True):
        """Wraps: mpv_set_option"""
        assert self._ctx
        prop = _strenc(prop.replace('_','-'))
        cdef mpv_format fmt = self._format_for(value)
        cdef mpv_node v = self._prep_native_value(value, fmt)
        cdef int err
        cdef const char* prop_c
        try:
            prop_c = prop
            with nogil:
                err = mpv_set_option(
                    self._ctx,
                    prop_c,
                    MPV_FORMAT_NODE,
                    &v
                )
        finally:
            self._free_native_value(v)
        if err < 0: raise MPVError(err)
        return Error(err)

    def wait_event(self, timeout=None):
        """Wraps: mpv_wait_event"""
        assert self._ctx
        cdef double timeout_d = timeout if timeout is not None else 0
        cdef mpv_event* event = NULL
        with nogil:
            event = mpv_wait_event(self._ctx, timeout_d)
        return Event.create(event,self)

    def wakeup(self):
        """Wraps: mpv_wakeup"""
        assert self._ctx
        with nogil:
            mpv_wakeup(self._ctx)

    def set_wakeup_callback(self, callback):
        """Wraps: mpv_set_wakeup_callback"""
        assert self._ctx
        cdef uint64_t ctxid = <uint64_t>id(self)
        if isinstance(self.callback, CallbackThread):
            self.callback.shutdown()
            self.callback = None
        if callback is not None:
            _callbacks[ctxid] = self.callback = callback;
        elif ctxid in _callbacks:
            del _callbacks[ctxid]
        _callbacks[ctxid] = self.callback
        with nogil:
            mpv_set_wakeup_callback(self._ctx, _c_callback, <void*>ctxid)

    def set_wakeup_callback_thread(self, callback):
        """Wraps: mpv_set_wakeup_callback"""
        assert self._ctx
        cdef uint64_t ctxid = <uint64_t>id(self)

#        self.callback = callback
        if callback:
            if not self.callbackthread or not isinstance(self.callbackthread, CallbackThread) or not self.callbackthread.is_alive():
                self.callback = callback
                _callbacks[ctxid] = self.callbackthread = CallbackThread(str(ctxid))
                self.callbackthread.set(self.callback)
                self.callbackthread.start()
            else:
                self.callback = callback
                _callbacks[ctxid] = self.callbackthread
                self.callbackthread.set(self.callback)
            with nogil:
                mpv_set_wakeup_callback(self._ctx, _c_callback, <void*>ctxid)

        else:
            if self.callbackthread and self.callbackthread.is_alive():
                self.callbackthread.shutdown()
            self.callbackthread = None
            self.callback       = None
            if ctxid in _callbacks:
                del _callbacks[ctxid]
            with nogil:
                mpv_set_wakeup_callback(self._ctx, _c_callback, <void*>ctxid)

    def get_wakeup_pipe(self):
        """Wraps: mpv_get_wakeup_pipe"""
        assert self._ctx
        cdef int pipe = -1
        with nogil:
            pipe = mpv_get_wakeup_pipe(self._ctx)
        return pipe

    def __cinit__(self, *args, **kwargs):
        cdef uint64_t ctxid = <uint64_t>id(self)
        cdef int err = 0
        self._ctx = NULL
        cdef mpv_handle *_ctx = NULL
        cdef Context other = None
        cdef str name
        cdef const char *c_name = NULL
        _other = kwargs.pop('other',None)
        if isinstance(other, Context):
            other = _other
            _ctx = other._ctx
            name = kwargs.pop('name','client')
            c_name = name
            with nogil:
                self._ctx = mpv_create_client(_ctx,c_name)
            if not self._ctx:
                raise MPVError("Context creation error")
        else:
            with nogil:
                self._ctx = mpv_create()
            if not self._ctx:
                raise MPVError("Context creation error")
            for op in args:
                try:    self.set_option(op)
                except: pass
            for op,val in kwargs.items():
                try:    self.set_option(op,val)
                except: pass
            with nogil:
                err = mpv_initialize(self._ctx)
            if err != 0:
                with nogil:
                    mpv_terminate_destroy(self._ctx)
                self._ctx = NULL
                raise MPVError(err)
        cdef const char *loglevel_c = "terminal-default";
        mpv_request_log_messages(self._ctx, loglevel_c)
#    def __init__(self, *args, **kwargs):
#        cdef uint64_t ctxid = <uint64_t>id(self)
#        cdef int err = 0
        self.properties = set()
        self.options    = set()
        self._opts      = dict()
        self._props     = dict()
#        _callbacks[ctxid] = self.callbackthread = CallbackThread(str(ctxid))
        _reply_userdatas[ctxid] = self.reply_userdata = UserDict()
#        self.callbackthread.start()
        property_list = set(self.get_property("property-list"))
        options       = set(self.get_property('options'))

        for op in options:
            try:
                name = self.get_property("option-info/{}/name".format(op))
                self._opts[op] = name
                self._opts[op.replace('-','_')] = name
                self._opts[op.replace('_','-')] = name
                if op == name:
                    self.options.add(op)
            except MPVError:
                pass
#            self.options.add(op.replace('_','-'))
        for prop in property_list | options:
            try:
                try:
                    self.get_property(prop)
                except MPVError as e:
                    if e.code in ( Error.property_not_found,Error.option_not_found):
                        continue
                self._props[prop]                  = prop
                self._props[prop.replace('-','_')] = prop
#                self._props[prop.replace('_','-')] = prop
                if prop in self.options or prop not in self._opts:
                    self.properties.add(prop)
            except:pass
        for op in args:
            try:    self.set_option(op)
            except: pass
        for op,val in kwargs.items():
            try:    self.set_option(op,val)
            except: pass

    def property_name(self, prop):
        name = self._props.get(prop,None)
        if name:
            return name
        else:
            raise MPVError(Error.property_not_found)
    def option_name(self, prop):
        name = self._opts.get(prop,None)
        if name:
            return name
        else:
            raise MPVError(Error.option_not_found)
    def attr_name(self, name):
        res = self._props.get(name,None) or self._opts.get(name,None)
        if not res:
            raise AttributeError('no property or option {}'.format(name))
        return res
    def copy(self,name='dup', *args, **kwargs):
        return Context(other=self,name=name, *args, **kwargs)

    def observe_property(self, prop, data=None):
        """Wraps: mpv_observe_property"""
        assert self._ctx
        cdef uint64_t id_data = <uint64_t>hash(data)

        userdatas = self.reply_userdata.get(id_data, None)

        if userdatas is None:
            self.reply_userdata[id_data] = userdatas = _ReplyUserData(data,self.reply_userdata)

        userdatas.incref()
        prop = _strenc(prop)
        cdef char* propc = prop
        cdef int err = 0
        with nogil:
            err = mpv_observe_property(
                self._ctx,
                id_data,
                propc,
                MPV_FORMAT_NODE,
            )
        if  err < 0:
            raise MPVError(err)
        return Error(err);

    def unobserve_property(self, data):
        """Wraps: mpv_unobserve_property"""
        assert self._ctx
        cdef uint64_t id_data = <uint64_t>hash(data)
        cdef int err = 0
        userdatas = self.reply_userdata.get(id_data, None)
        if userdatas is not None:
            userdatas.decref()
        with nogil:
            err = mpv_unobserve_property(
                self._ctx,
                id_data,
            )
        if  err < 0:
            raise MPVError(err)
        return Error(err);

    def detach(self):
        cdef uint64_t ctxid = <uint64_t>id(self)
        if self.callbackthread is not None:
            self.callbackthread.shutdown()
        cdef mpv_handle *_ctx = self._ctx
        self._ctx = NULL
        if _ctx != NULL:
            with nogil:
                mpv_detach_destroy(_ctx)

        if ctxid in _callbacks:      del _callbacks[ctxid]
        if ctxid in _reply_userdatas:del _reply_userdatas[ctxid]
        self.callback       = None
        self.reply_userdata = None

    def shutdown(self):
        cdef uint64_t ctxid = <uint64_t>id(self)
        if self.callbackthread is not None:
            self.callbackthread.shutdown()

        if self.cb_context:
            cb_context = self.cb_context()
            self.cb_context = None
            if cb_context:
                cb_context.shutdown()
                del cb_context

        cdef mpv_handle *_ctx = self._ctx
        self._ctx = NULL
        if _ctx != NULL:
            with nogil:
                mpv_terminate_destroy(_ctx)

        if ctxid in _callbacks:      del _callbacks[ctxid]
        if ctxid in _reply_userdatas:del _reply_userdatas[ctxid]
        self.callback       = None
        self.reply_userdata = None

    def __dealloc__(self):
        self.detach()

    @property
    def opengl_cb_context(self):
        return OpenGLCBContext.create(self)

    @property
    def opt_info(self):
        return OptionInfoProxy(self)

    @property
    def opts(self):
        return OptionsProxy(self)

cdef class OpenGLCBContext(object):
    cdef object __weakref__
    cdef mpv_opengl_cb_context *_glctx
    cdef readonly Context ctx
    cdef readonly object update_cb
    cdef readonly object update_thread

    @staticmethod
    cdef OpenGLCBContext create(Context ctx):
        cdef OpenGLCBContext locked = None
        if ctx and ctx.cb_context:
            locked = ctx.cb_context()
            if locked:
                return locked
        locked = OpenGLCBContext()
        locked.ctx = ctx
        cdef mpv_handle *_ctx = ctx._ctx
        locked._glctx = <mpv_opengl_cb_context*>mpv_get_sub_api(_ctx,MPV_SUB_API_OPENGL_CB)
        if locked._glctx == NULL:
            return
        ctx.cb_context = weakref.ref(locked)
        return locked

    def shutdown(self):
        if self.update_thread is not None:
            self.update_thread.shutdown()
            self.update_thread = None

        if self.update_cb:
            self.set_update_callback(None)

        cdef mpv_opengl_cb_context *_glctx = self._glctx
        self._glctx = NULL
        if _glctx:
            mpv_opengl_cb_uninit_gl(_glctx)
        if self.ctx and self.ctx.cb_context and self.ctx.cb_context() is self:
            self.ctx.cb_context = None

    def __dealloc__(self):
        self.shutdown()

    def init_gl(self, get_proc_address_cb, str exts = None):
        if not get_proc_address_cb or not self._glctx:
            return
        cdef const char *extsp = NULL
        if exts is not None:
            extsp = <const char*>exts
        cdef uint64_t name = <uint64_t>id(self)
        _callbacks[name] = get_proc_address_cb
        cdef int ret = mpv_opengl_cb_init_gl(self._glctx, extsp, &_c_getprocaddress, <void*>name)
        del _callbacks[name]
        if ret < 0:
            raise MPVError(ret)
    def set_update_callback(self, callback):
        """Wraps: mpv_set_wakeup_callback"""
        assert self._glctx
        cdef uint64_t ctxid = <uint64_t>id(self)
        if isinstance(self.update_cb, CallbackThread):
            self.update_cb.shutdown()
            self.update_cb= None
        if callback is not None:
            _callbacks[ctxid] = self.update_cb = callback;
        elif ctxid in _callbacks:
            del _callbacks[ctxid]
#        _callbacks[ctxid] = self.update_cb
        with nogil:
            mpv_opengl_cb_set_update_callback(self._glctx, _c_callback, <void*>ctxid)

    def set_update_callback_thread(self, callback):
        """Wraps: mpv_set_wakeup_callback"""
        assert self._glctx
        cdef uint64_t ctxid = <uint64_t>id(self)

#        self.callback = callback
        if not isinstance(self.update_cb, CallbackThread):
            self.update_cb = CallbackThread(str(ctxid))
            self.update_cb.set(callback)
            self.update_cb.start()
        elif self.update_cb:
            self.update_cb.set(callback)
        if self.update_thread is None:
            _callbacks[ctxid] = self.update_thread = CallbackThread(str(ctxid))
            self.update_thread.set(callback)
            self.update_thread.start()
        else:
            self.update_thread.set(callback)
        with nogil:
            mpv_opengl_cb_set_update_callback(self._glctx, _c_callback, <void*>ctxid)


    def draw(self, int fbo, int w, int h):
        cdef int err
        with nogil:
            err = mpv_opengl_cb_draw(self._glctx, fbo, w, h)
        if err < 0:
            raise MPVError(err)

    def report_flip(self, when):
        cdef int64_t time = <int64_t>when
        cdef int err
        with nogil:
            err = mpv_opengl_cb_report_flip(self._glctx, time)
        if err < 0:
            raise MPVError(err)


cdef void mpv_callback(callback):
    if callback is not None:
        try: callback()
        except Exception as e:
            sys.stderr.write("pympv error during callback: {}\n".format(e))
            sys.stderr.flush()

#cdef mpv_callback(cb):
#    if cb: _mpv_callback(cb)

class CallbackThread(Thread):

    def __init__(self, name=None):
        super().__init__(name=(
            name + "-mpv-cbthread" if name else "mpv-cbthread")
         ,  daemon = True)
        self.daemon    = True
        self.cb  = thread_exit
        self.cbq = Queue()

    def shutdown(self):
        self.cb = None
        if self.isAlive():
            self.cbq.put(thread_exit)

    def __call__(self, cb = None):
        self.cbq.put(cb or self.cb)

    def set(self, cb):
        self.cb = cb

    def run(self):
        while True:
            try:
                cb = self.cbq.get()
            else:
                mpv_callback(cb)
            finally:
                self.cbq.task_done()

cdef void *_c_getprocaddress(void *d, const char *fname) with gil:
    cdef uint64_t name = <uint64_t>d
    cb = _callbacks.get(name,None)
    cdef uint64_t res = 0
    if cb:
        res = <uint64_t>cb(_strenc(fname))
    return <void*>res

cdef void _c_callback(void* d) with gil:
    cdef uint64_t name = <uint64_t>d
    cb = _callbacks.get(name,None)
    if cb: mpv_callback(cb)
