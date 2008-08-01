/**
 * This module contains functions and structures required for
 * exception handling.
 */
module eh;

import util.console;

// debug = EH_personality;

// current EH implementation works on x86 linux only
version(X86) version(linux) version=X86_LINUX;

private extern(C) void abort();
private extern(C) int printf(char*, ...);

// D runtime functions
extern(C) {
    int _d_isbaseof(ClassInfo oc, ClassInfo c);
}

// libunwind headers
extern(C)
{
    enum _Unwind_Reason_Code
    {
        NO_REASON = 0,
        FOREIGN_EXCEPTION_CAUGHT = 1,
        FATAL_PHASE2_ERROR = 2,
        FATAL_PHASE1_ERROR = 3,
        NORMAL_STOP = 4,
        END_OF_STACK = 5,
        HANDLER_FOUND = 6,
        INSTALL_CONTEXT = 7,
        CONTINUE_UNWIND = 8
    }

    enum _Unwind_Action
    {
        SEARCH_PHASE = 1,
        CLEANUP_PHASE = 2,
        HANDLER_PHASE = 3,
        FORCE_UNWIND = 4
    }

    alias void* _Unwind_Context_Ptr;

    alias void function(_Unwind_Reason_Code, _Unwind_Exception*) _Unwind_Exception_Cleanup_Fn;

    struct _Unwind_Exception
    {
        char[8] exception_class;
        _Unwind_Exception_Cleanup_Fn exception_cleanup;
        int private_1;
        int private_2;
    }

version(X86_LINUX) 
{
    void _Unwind_Resume(_Unwind_Exception*);
    _Unwind_Reason_Code _Unwind_RaiseException(_Unwind_Exception*);
    ulong _Unwind_GetLanguageSpecificData(_Unwind_Context_Ptr context);
    ulong _Unwind_GetIP(_Unwind_Context_Ptr context);
    ulong _Unwind_SetIP(_Unwind_Context_Ptr context, ulong new_value);
    ulong _Unwind_SetGR(_Unwind_Context_Ptr context, int index, ulong new_value);
    ulong _Unwind_GetRegionStart(_Unwind_Context_Ptr context);
}
else
{
    // runtime calls these directly
    void _Unwind_Resume(_Unwind_Exception*)
    {
        console("_Unwind_Resume is not implemented on this platform.\n");
    }
    _Unwind_Reason_Code _Unwind_RaiseException(_Unwind_Exception*)
    {
        console("_Unwind_RaiseException is not implemented on this platform.\n");
        return _Unwind_Reason_Code.FATAL_PHASE1_ERROR;
    }
}

}


// helpers for reading certain DWARF data
//TODO: It may not be a good idea to use exceptions for error handling within exception handling code
private ubyte* get_uleb128(ubyte* addr, ref size_t res)
{
  res = 0;
  size_t bitsize = 0;

  // read as long as high bit is set
  while(*addr & 0x80) {
    res |= (*addr & 0x7f) << bitsize;
    bitsize += 7;
    addr += 1;
    if(bitsize >= size_t.sizeof*8)
       throw new Exception("tried to read uleb128 that exceeded size of size_t");
  }
  // read last
  if(bitsize != 0 && *addr >= 1 << size_t.sizeof*8 - bitsize)
    throw new Exception("tried to read uleb128 that exceeded size of size_t");
  res |= (*addr) << bitsize;

  return addr + 1;
}

private ubyte* get_sleb128(ubyte* addr, ref ptrdiff_t res)
{
  res = 0;
  size_t bitsize = 0;

  // read as long as high bit is set
  while(*addr & 0x80) {
    res |= (*addr & 0x7f) << bitsize;
    bitsize += 7;
    addr += 1;
    if(bitsize >= size_t.sizeof*8)
       throw new Exception("tried to read sleb128 that exceeded size of size_t");
  }
  // read last
  if(bitsize != 0 && *addr >= 1 << size_t.sizeof*8 - bitsize)
    throw new Exception("tried to read sleb128 that exceeded size of size_t");
  res |= (*addr) << bitsize;

  // take care of sign
  if(bitsize < size_t.sizeof*8 && ((*addr) & 0x40))
    res |= cast(ptrdiff_t)(-1) ^ ((1 << (bitsize+7)) - 1);

  return addr + 1;
}


// exception struct used by the runtime.
// _d_throw allocates a new instance and passes the address of its
// _Unwind_Exception member to the unwind call. The personality
// routine is then able to get the whole struct by looking at the data
// surrounding the unwind info.
struct _d_exception
{
  Object exception_object;
  _Unwind_Exception unwind_info;
}

// the 8-byte string identifying the type of exception
// the first 4 are for vendor, the second 4 for language
//TODO: This may be the wrong way around
char[8] _d_exception_class = "LLDCD1\0\0";


//
// x86 Linux specific implementation of personality function
// and helpers
//
version(X86_LINUX) 
{

// the personality routine gets called by the unwind handler and is responsible for
// reading the EH tables and deciding what to do
extern(C) _Unwind_Reason_Code _d_eh_personality(int ver, _Unwind_Action actions, ulong exception_class, _Unwind_Exception* exception_info, _Unwind_Context_Ptr context)
{
  // check ver: the C++ Itanium ABI only allows ver == 1
  if(ver != 1)
    return _Unwind_Reason_Code.FATAL_PHASE1_ERROR;

  // check exceptionClass
  //TODO: Treat foreign exceptions with more respect
  if((cast(char*)&exception_class)[0..8] != _d_exception_class)
    return _Unwind_Reason_Code.FATAL_PHASE1_ERROR;

  // find call site table, action table and classinfo table
  // Note: callsite and action tables do not contain static-length
  // data and will be parsed as needed
  // Note: classinfo_table points past the end of the table
  ubyte* callsite_table;
  ubyte* action_table;
  ClassInfo* classinfo_table;
  _d_getLanguageSpecificTables(context, callsite_table, action_table, classinfo_table);


  /*
    find landing pad and action table index belonging to ip by walking
    the callsite_table
  */
  ubyte* callsite_walker = callsite_table;

  // get the instruction pointer
  // will be used to find the right entry in the callsite_table
  // -1 because it will point past the last instruction
  ulong ip = _Unwind_GetIP(context) - 1;

  // address block_start is relative to
  ulong region_start = _Unwind_GetRegionStart(context);

  // table entries
  uint block_start_offset, block_size;
  ulong landing_pad;
  size_t action_offset;

  while(true) {
    // if we've gone through the list and found nothing...
    if(callsite_walker >= action_table)
      return _Unwind_Reason_Code.CONTINUE_UNWIND;

    block_start_offset = *cast(uint*)callsite_walker;
    block_size = *(cast(uint*)callsite_walker + 1);
    landing_pad = *(cast(uint*)callsite_walker + 2);
    if(landing_pad)
      landing_pad += region_start;
    callsite_walker = get_uleb128(callsite_walker + 3*uint.sizeof, action_offset);

    debug(EH_personality_verbose) printf("%d %d %d\n", block_start_offset, block_size, landing_pad);

    // since the list is sorted, as soon as we're past the ip
    // there's no handler to be found
    if(ip < region_start + block_start_offset)
      return _Unwind_Reason_Code.CONTINUE_UNWIND;

    // if we've found our block, exit
    if(ip < region_start + block_start_offset + block_size)
      break;
  }

  debug(EH_personality) printf("Found correct landing pad and actionOffset %d\n", action_offset);

  // now we need the exception's classinfo to find a handler
  // the exception_info is actually a member of a larger _d_exception struct
  // the runtime allocated. get that now
  _d_exception* exception_struct = cast(_d_exception*)(cast(ubyte*)exception_info - _d_exception.unwind_info.offsetof);

  // if there's no action offset and no landing pad, continue unwinding
  if(!action_offset && !landing_pad)
    return _Unwind_Reason_Code.CONTINUE_UNWIND;

  // if there's no action offset but a landing pad, this is a cleanup handler
  else if(!action_offset && landing_pad)
    return _d_eh_install_finally_context(actions, landing_pad, exception_struct, context);

  /*
   walk action table chain, comparing classinfos using _d_isbaseof
  */
  ubyte* action_walker = action_table + action_offset - 1;

  ptrdiff_t ti_offset, next_action_offset;
  while(true) {
    action_walker = get_sleb128(action_walker, ti_offset);
    // it is intentional that we not modify action_walker here
    // next_action_offset is from current action_walker position
    get_sleb128(action_walker, next_action_offset);

    // negative are 'filters' which we don't use
    assert(ti_offset >= 0 && "Filter actions are unsupported");

    // zero means cleanup, which we require to be the last action
    if(ti_offset == 0) {
      assert(next_action_offset == 0 && "Cleanup action must be last in chain");
      return _d_eh_install_finally_context(actions, landing_pad, exception_struct, context);
    }

    // get classinfo for action and check if the one in the
    // exception structure is a base
    ClassInfo catch_ci = classinfo_table[-ti_offset];
    debug(EH_personality) printf("Comparing catch %s to exception %s\n", catch_ci.name.ptr, exception_struct.exception_object.classinfo.name.ptr);
    if(_d_isbaseof(exception_struct.exception_object.classinfo, catch_ci))
      return _d_eh_install_catch_context(actions, ti_offset, landing_pad, exception_struct, context);

    // we've walked through all actions and found nothing...
    if(next_action_offset == 0)
      return _Unwind_Reason_Code.CONTINUE_UNWIND;
    else
      action_walker += next_action_offset;
  }

  assert(false);
}

// These are the register numbers for SetGR that
// llvm's eh.exception and eh.selector intrinsics
// will pick up.
// Found by trial-and-error and probably platform dependent!
private int eh_exception_regno = 0;
private int eh_selector_regno = 2;

private _Unwind_Reason_Code _d_eh_install_catch_context(_Unwind_Action actions, ptrdiff_t switchval, ulong landing_pad, _d_exception* exception_struct, _Unwind_Context_Ptr context)
{
  debug(EH_personality) printf("Found catch clause!\n");

  if(actions & _Unwind_Action.SEARCH_PHASE)
    return _Unwind_Reason_Code.HANDLER_FOUND;

  else if(actions & _Unwind_Action.HANDLER_PHASE)
  {
    debug(EH_personality) printf("Setting switch value to: %d!\n", switchval);
    _Unwind_SetGR(context, eh_exception_regno, cast(ulong)cast(void*)(exception_struct.exception_object));
    _Unwind_SetGR(context, eh_selector_regno, switchval);
    _Unwind_SetIP(context, landing_pad);
    return _Unwind_Reason_Code.INSTALL_CONTEXT;
  }

  assert(false);
}

private _Unwind_Reason_Code _d_eh_install_finally_context(_Unwind_Action actions, ulong landing_pad, _d_exception* exception_struct, _Unwind_Context_Ptr context)
{
  // if we're merely in search phase, continue
  if(actions & _Unwind_Action.SEARCH_PHASE)
    return _Unwind_Reason_Code.CONTINUE_UNWIND;

  debug(EH_personality) printf("Calling cleanup routine...\n");

  _Unwind_SetGR(context, eh_exception_regno, cast(ulong)exception_struct);
  _Unwind_SetGR(context, eh_selector_regno, 0);
  _Unwind_SetIP(context, landing_pad);
  return _Unwind_Reason_Code.INSTALL_CONTEXT;
}

private void _d_getLanguageSpecificTables(_Unwind_Context_Ptr context, ref ubyte* callsite, ref ubyte* action, ref ClassInfo* ci)
{
  ubyte* data = cast(ubyte*)_Unwind_GetLanguageSpecificData(context);

  //TODO: Do proper DWARF reading here
  assert(*data++ == 0xff);

  assert(*data++ == 0x00);
  size_t cioffset;
  data = get_uleb128(data, cioffset);
  ci = cast(ClassInfo*)(data + cioffset);

  assert(*data++ == 0x03);
  size_t callsitelength;
  data = get_uleb128(data, callsitelength);
  action = data + callsitelength;

  callsite = data;
}

} // end of x86 Linux specific implementation


extern(C) void _d_throw_exception(Object e)
{
    if (e !is null)
    {
        _d_exception* exc_struct = new _d_exception;
        exc_struct.unwind_info.exception_class[] = _d_exception_class;
        exc_struct.exception_object = e;
        _Unwind_Reason_Code ret = _Unwind_RaiseException(&exc_struct.unwind_info);
        console("_Unwind_RaiseException failed with reason code: ")(ret)("\n");
    }
    abort();
}

extern(C) void _d_eh_resume_unwind(_d_exception* exception_struct)
{
  _Unwind_Resume(&exception_struct.unwind_info);
}