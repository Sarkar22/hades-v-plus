/* SPDX-License-Identifier: MIT
 * ---------------------------------------------------------------------
 * File: hpm.h
 *
 * The hardware performance counters of HaDes-V+ from C (docs/EXTENSIONS.md, "Hardware
 * Performance Counters"): the machine-mode counters mhpmcounter3..9 (0xB03..0xB09, high halves
 * 0xB83..0xB89), their event selectors mhpmevent3..9 (0x323..0x329) and the register
 * mcountinhibit (0x320). Counter n (3..9) counts the event whose code its selector holds.
 *
 * Use
 *     unsigned n = hpm_counters();                 how many programmable counters there are (0: none)
 *     if( n >= 1 )
 *     {
 *         hpm_select( 3, HPM_EV_BR_MISPREDICT );     -- the codes are below
 *         hpm_write( 3, 0 );
 *         hpm_thaw( 1u << 3 );                       start counter 3
 *         ... code to measure ...
 *         hpm_freeze( 1u << 3 );                     stop it
 *         uint64_t count = hpm_read( 3 );
 *     }
 *
 * Rules (the design behind them: docs/EXTENSIONS.md)
 *  - Freeze a counter before you change its selector. An event that is still on its way to the
 *    counter when the selector changes is counted under the new selector. hpm_select() does this.
 *  - The counters count everything the CPU does: other tasks, interrupt handlers and the code of
 *    this header's own functions. To measure one piece of code, freeze right before and thaw right
 *    after, in straight-line code that is already in the cache and in the pipeline; the events of
 *    the front end (instruction fetch, hazards) can fall up to about three instructions to either
 *    side of the edge of a window. Events from Execute on (retirement, redirects, stalls of the
 *    M unit and of the data bus, traps) fall exactly in program order.
 *  - A 64-bit counter is read in two halves. Freeze it first, or use hpm_read(), which reads the
 *    high half, the low half and the high half again until the high half is stable.
 *  - A counter is 48 bits wide in the CPU by default (the build parameter HADES_HPM_WIDTH, 32 to
 *    64); the bits above read 0.
 *  - hpm_freeze() and hpm_thaw() touch bits 3..13 of mcountinhibit only, so they can never stop
 *    mcycle or minstret by accident. hpm_freeze_cycle_instret() and hpm_thaw_cycle_instret() are
 *    the only functions that touch those two. The FreeRTOS shell's `stats` command uses mcycle as
 *    its clock (docs/SHELL.md) and the trap sweep relies on minstret: do not leave them frozen.
 *  - The counters 10..13 (mhpmcounter10..13) belong to the branch predictor and count retired
 *    conditional branches by prediction and outcome; their selectors read the constants 18, 19, 20
 *    (mhpmevent11..13) and the predictor's mode (mhpmevent10). They are not used here.
 *  - On the golden CPU the selectors read 0 and ignore writes (or trap), so hpm_counters() returns
 *    0 and nothing else of this file should be used.
 *
 * The event codes are those of the CPU (defines/hpm.sv); a code is never renumbered or reused.
 * hpm_select() returns what the selector holds after the write: 0 means that this build has no such
 * event (the memory-system codes 128..191 exist only where a cache is built).
 *
 * Define HPM_WITH_NAMES before including this file to get hpm_event_name() and HPM_EVENT_LIST(),
 * which cost code space and are meant for tools such as the shell's `perf` command.
 */

#ifndef HPM_H
#define HPM_H

#include <stdint.h>

/* ------------------------------------------------------------------------ counters -- */

#define HPM_FIRST             3u       /* the first programmable counter */
#define HPM_MAX               7u       /* the most counters a build has: 3..9 */

/* mcountinhibit (0x320) */
#define HPM_INH_CY            ( 1u << 0 )      /* mcycle stops */
#define HPM_INH_IR            ( 1u << 2 )      /* minstret stops */
#define HPM_INH_PROG          0x000003F8u      /* counters 3..9 */
#define HPM_INH_BP            0x00003C00u      /* the predictor's counters 10..13 */
#define HPM_INH_USER          ( HPM_INH_PROG | HPM_INH_BP )   /* what hpm_freeze() and hpm_thaw() may touch */

/* ---------------------------------------------------------------------- event codes -- */

/* architectural events: codes 1-20 are counted at the end of the cycle in which the instruction is
 * in Writeback; the trap events 21-26 two cycles after the trap decision */
#define HPM_EV_NONE             0u     /* counts nothing */
#define HPM_EV_CYCLE            1u
#define HPM_EV_INSTRET          2u
#define HPM_EV_LOAD             3u
#define HPM_EV_STORE            4u
#define HPM_EV_BRANCH           5u
#define HPM_EV_BRANCH_TAKEN     6u
#define HPM_EV_JUMP             7u
#define HPM_EV_MUL              8u
#define HPM_EV_DIV              9u
#define HPM_EV_CSR              10u
#define HPM_EV_BITMANIP         11u
#define HPM_EV_CRYPTO           12u
#define HPM_EV_MRET             13u
#define HPM_EV_FENCE_I          14u
#define HPM_EV_REPLAY           15u
#define HPM_EV_BR_MISPREDICT    16u
#define HPM_EV_BP_NN            17u
#define HPM_EV_BP_NT            18u
#define HPM_EV_BP_TN            19u
#define HPM_EV_BP_TT            20u
#define HPM_EV_EXCEPTION        21u
#define HPM_EV_EXC_ECALL        22u
#define HPM_EV_EXC_OTHER        23u
#define HPM_EV_INTERRUPT        24u
#define HPM_EV_INT_TIMER        25u
#define HPM_EV_INT_EXT          26u

/* pipeline events */
#define HPM_EV_FETCH_WAIT       32u    /* the six cycle classes 32..37 add up to the cycle count */
#define HPM_EV_FRONT_OK         33u
#define HPM_EV_HAZARD           34u
#define HPM_EV_MSTALL_ANY       35u
#define HPM_EV_MEMWAIT_ANY      36u
#define HPM_EV_REDIRECT_ANY     37u
#define HPM_EV_HAZARD_LOAD      38u
#define HPM_EV_MSTALL_MUL       39u
#define HPM_EV_MSTALL_DIV       40u
#define HPM_EV_MEMWAIT_LOAD     41u
#define HPM_EV_MEMWAIT_STORE    42u
#define HPM_EV_MEMWAIT_IO       43u
#define HPM_EV_REDIRECT_BRANCH  44u
#define HPM_EV_REDIRECT_JUMP    45u
#define HPM_EV_REDIRECT_WB      46u
#define HPM_EV_FETCH_DELIVER    47u
#define HPM_EV_FETCH_DISCARD    48u
#define HPM_EV_IO_ACCESS        49u

/* memory-system events: only in a build with an instruction cache */
#define HPM_EV_IC_LOOKUP_HIT    128u
#define HPM_EV_IC_MISS          129u
#define HPM_EV_IC_BEAT          130u
#define HPM_EV_IC_FILL          131u
#define HPM_EV_IC_ABANDON       132u
#define HPM_EV_IC_SNOOP_INVAL   133u
#define HPM_EV_PORT_WAIT_I      134u
#define HPM_EV_PORT_WAIT_D      135u
#define HPM_EV_PORT_GRANT_I     136u
#define HPM_EV_PORT_GRANT_D     137u
#define HPM_EV_PORT_LOAD        138u
#define HPM_EV_PORT_STORE       139u
#define HPM_EV_IC_HIT_USED      160u
#define HPM_EV_IC_MISS_JUMP     161u

/* -------------------------------------------------------------------- CSR access -- */

/* A CSR number must be an immediate, so each access is a switch over the counter number. */
#define HPM_CSR_STR_( x )    #x

#define HPM_COUNTER_LIST_( X )                                              \
    X( 3, 0xB03, 0xB83, 0x323 ) X( 4, 0xB04, 0xB84, 0x324 )                 \
    X( 5, 0xB05, 0xB85, 0x325 ) X( 6, 0xB06, 0xB86, 0x326 )                 \
    X( 7, 0xB07, 0xB87, 0x327 ) X( 8, 0xB08, 0xB88, 0x328 )                 \
    X( 9, 0xB09, 0xB89, 0x329 )

static inline uint32_t hpm_inhibit_read( void )
{
    uint32_t v;
    __asm volatile ( "csrr %0, 0x320" : "=r" ( v ) );
    return v;
}

/* Stop the counters in mask (bits 3..13 only); the others keep running. Returns when the
 * csrrs has retired: events of the instructions before it, and its own, are counted; those after it
 * are not. (A thaw is the mirror image: the csrrc itself is not counted.) */
static inline void hpm_freeze( uint32_t ulMask )
{
    ulMask &= HPM_INH_USER;
    __asm volatile ( "csrrs zero, 0x320, %0" : : "r" ( ulMask ) : "memory" );
}

/* Start the counters in mask (bits 3..13 only). */
static inline void hpm_thaw( uint32_t ulMask )
{
    ulMask &= HPM_INH_USER;
    __asm volatile ( "csrrc zero, 0x320, %0" : : "r" ( ulMask ) : "memory" );
}

/* The only functions that touch mcycle's and minstret's inhibit bits (see the rules above). */
static inline void hpm_freeze_cycle_instret( void )
{
    __asm volatile ( "csrrs zero, 0x320, %0" : : "r" ( HPM_INH_CY | HPM_INH_IR ) : "memory" );
}

static inline void hpm_thaw_cycle_instret( void )
{
    __asm volatile ( "csrrc zero, 0x320, %0" : : "r" ( HPM_INH_CY | HPM_INH_IR ) : "memory" );
}

/* The selector of counter n (HPM_FIRST..HPM_FIRST+HPM_MAX-1): the event code it holds, 0 if none.
 * Any other n reads 0. */
static inline uint32_t hpm_selector( unsigned uN )
{
    uint32_t v = 0;

    switch( uN )
    {
        #define HPM_CASE_( n, lo, hi, sel ) \
            case n: __asm volatile ( "csrr %0, " HPM_CSR_STR_( sel ) : "=r" ( v ) ); break;
        HPM_COUNTER_LIST_( HPM_CASE_ )
        #undef HPM_CASE_
        default: break;
    }

    return v;
}

/* Write the selector of counter n as it is (no freeze): see hpm_select(). */
static inline void hpm_selector_write( unsigned uN, uint32_t ulCode )
{
    switch( uN )
    {
        #define HPM_CASE_( n, lo, hi, sel ) \
            case n: __asm volatile ( "csrw " HPM_CSR_STR_( sel ) ", %0" : : "r" ( ulCode ) ); break;
        HPM_COUNTER_LIST_( HPM_CASE_ )
        #undef HPM_CASE_
        default: break;
    }
}

/* How many programmable counters this CPU has: 0..HPM_MAX. It writes the code 1 (HPM_EV_CYCLE)
 * into mhpmevent3, mhpmevent4, ... one at a time and reads each back, and puts every selector back
 * as it was. It does not write mcountinhibit. A selector that does not exist reads 0 whatever is
 * written (or the access traps, on a CPU without counters, which the caller must expect). A
 * counter that is running may count a few events of the probe under the other selector. */
static inline unsigned hpm_counters( void )
{
    unsigned uCount = 0;

    for( unsigned n = HPM_FIRST; n < HPM_FIRST + HPM_MAX; n++ )
    {
        const uint32_t ulSaved = hpm_selector( n );
        uint32_t ulRead;

        hpm_selector_write( n, HPM_EV_CYCLE );
        ulRead = hpm_selector( n );
        hpm_selector_write( n, ulSaved );

        if( ulRead != HPM_EV_CYCLE )
        {
            break;
        }

        uCount++;
    }

    return uCount;
}

/* Freeze counter n, give it the event code, and return what the selector holds afterwards: the
 * code, or 0 if this build does not have the event (the counter then counts nothing). The counter
 * is left frozen, with its old value, for the caller to clear and start. */
static inline uint32_t hpm_select( unsigned uN, uint32_t ulCode )
{
    hpm_freeze( 1u << uN );
    hpm_selector_write( uN, ulCode );
    return hpm_selector( uN );
}

/* The 64-bit value of counter n: high, low, high again until the high half is stable. For a
 * running counter this is a consistent value at some moment of the call; for several counters at
 * once, freeze them first. */
static inline uint64_t hpm_read( unsigned uN )
{
    uint32_t h = 0, l = 0, h2 = 0;

    do
    {
        switch( uN )
        {
            #define HPM_CASE_( n, lo, hi, sel )                                  \
                case n:                                                          \
                    __asm volatile ( "csrr %0, " HPM_CSR_STR_( hi ) : "=r" ( h ) );  \
                    __asm volatile ( "csrr %0, " HPM_CSR_STR_( lo ) : "=r" ( l ) );  \
                    __asm volatile ( "csrr %0, " HPM_CSR_STR_( hi ) : "=r" ( h2 ) ); \
                    break;
            HPM_COUNTER_LIST_( HPM_CASE_ )
            #undef HPM_CASE_
            default: return 0;
        }
    } while( h != h2 );

    return ( ( uint64_t ) h << 32 ) | l;
}

/* Set counter n. Freeze it first: a running counter takes its increment of the same cycle into the
 * half that is not written. The bits above the counter's width are dropped by the CPU. */
static inline void hpm_write( unsigned uN, uint64_t ullValue )
{
    const uint32_t ulLo = ( uint32_t ) ullValue, ulHi = ( uint32_t ) ( ullValue >> 32 );

    switch( uN )
    {
        #define HPM_CASE_( n, lo, hi, sel )                                                 \
            case n:                                                                         \
                __asm volatile ( "csrw " HPM_CSR_STR_( hi ) ", %0" : : "r" ( ulHi ) );      \
                __asm volatile ( "csrw " HPM_CSR_STR_( lo ) ", %0" : : "r" ( ulLo ) );      \
                break;
        HPM_COUNTER_LIST_( HPM_CASE_ )
        #undef HPM_CASE_
        default: break;
    }
}

/* -------------------------------------------------------------------------- names -- */

#ifdef HPM_WITH_NAMES

/* Every event of the standard build and of the cached build, once: X( NAME ) for the code
 * HPM_EV_<NAME>. */
#define HPM_EVENT_LIST( X )                                                                          \
    X( CYCLE ) X( INSTRET ) X( LOAD ) X( STORE ) X( BRANCH ) X( BRANCH_TAKEN ) X( JUMP ) X( MUL )     \
    X( DIV ) X( CSR ) X( BITMANIP ) X( CRYPTO ) X( MRET ) X( FENCE_I ) X( REPLAY ) X( BR_MISPREDICT ) \
    X( BP_NN ) X( BP_NT ) X( BP_TN ) X( BP_TT ) X( EXCEPTION ) X( EXC_ECALL ) X( EXC_OTHER )          \
    X( INTERRUPT ) X( INT_TIMER ) X( INT_EXT ) X( FETCH_WAIT ) X( FRONT_OK ) X( HAZARD )              \
    X( MSTALL_ANY ) X( MEMWAIT_ANY ) X( REDIRECT_ANY ) X( HAZARD_LOAD ) X( MSTALL_MUL )               \
    X( MSTALL_DIV ) X( MEMWAIT_LOAD ) X( MEMWAIT_STORE ) X( MEMWAIT_IO ) X( REDIRECT_BRANCH )         \
    X( REDIRECT_JUMP ) X( REDIRECT_WB ) X( FETCH_DELIVER ) X( FETCH_DISCARD ) X( IO_ACCESS )          \
    X( IC_LOOKUP_HIT ) X( IC_MISS ) X( IC_BEAT ) X( IC_FILL ) X( IC_ABANDON ) X( IC_SNOOP_INVAL )     \
    X( PORT_WAIT_I ) X( PORT_WAIT_D ) X( PORT_GRANT_I ) X( PORT_GRANT_D ) X( PORT_LOAD )              \
    X( PORT_STORE ) X( IC_HIT_USED ) X( IC_MISS_JUMP )

/* The name of an event code ("CYCLE", "IC_MISS", ...), or NULL for a code that has none. */
static inline const char * hpm_event_name( uint32_t ulCode )
{
    switch( ulCode )
    {
        #define HPM_NAME_( name ) case HPM_EV_##name: return #name;
        HPM_EVENT_LIST( HPM_NAME_ )
        #undef HPM_NAME_
        default: return ( const char * ) 0;
    }
}

#endif /* HPM_WITH_NAMES */

#endif /* HPM_H */
