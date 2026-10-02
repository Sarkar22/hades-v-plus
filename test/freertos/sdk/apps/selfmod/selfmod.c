/* selfmod.c -- an app that writes code and runs it: the rules of fence.i.
 *
 * It writes "li a0, 42; ret" into a word-aligned buffer, executes fence.i and calls the
 * buffer; then it rewrites the same buffer in place to return 0x12345678 ("lui a0, 0x12345;
 * addi a0, a0, 0x678; ret"), executes fence.i and calls it again. The second call is the case
 * that an instruction cache or a prefetch buffer must handle: the old instructions at the same
 * addresses have just been executed. (The encodings are those of test/freertos/brk/main.c.)
 * Prints one line per call, then "selfmod: PASS" (exit code 0) or "selfmod: FAIL" (1). */
#include <stdint.h>
#include "hades_app.h"

/* RV32I encodings */
#define RV_LUI( rd, imm20 )          ( ( ( uint32_t ) ( imm20 ) << 12 ) | ( ( rd ) << 7 ) | 0x37u )
#define RV_ADDI( rd, rs1, imm12 )    ( ( ( ( uint32_t ) ( imm12 ) & 0xFFFu ) << 20 ) | ( ( rs1 ) << 15 ) | ( ( rd ) << 7 ) | 0x13u )
#define RV_RET                       0x00008067u   /* jalr x0, 0(ra) */
#define A0                           10u

typedef uint32_t ( * CodeFunction_t )( void );

static uint32_t aulCode[ 4 ] __attribute__( ( aligned( 16 ) ) );

/* Writes the instructions into the buffer, executes fence.i and calls it. */
static uint32_t prvRun( const uint32_t * pulInstructions, uint32_t ulCount )
{
    volatile uint32_t * const pulCode = aulCode;

    for( uint32_t i = 0; i < ulCount; i++ )
    {
        pulCode[ i ] = pulInstructions[ i ];
    }

    __asm volatile ( "fence.i" ::: "memory" );
    return ( ( CodeFunction_t ) ( uintptr_t ) aulCode )();
}

static int prvCheck( const char * pcInstructions, uint32_t ulGot, uint32_t ulExpected )
{
    app_printf( "selfmod: %s -> %lu (0x%08lx)%s\n", pcInstructions, ulGot, ulGot,
                ( ulGot == ulExpected ) ? "" : ", expected a different value" );
    return ulGot == ulExpected;
}

int main( void )
{
    const uint32_t aulFortyTwo[] = { RV_ADDI( A0, 0u, 42u ), RV_RET };
    const uint32_t aulLarge[] = { RV_LUI( A0, 0x12345u ), RV_ADDI( A0, A0, 0x678u ), RV_RET };
    int iPass = 1;

    iPass &= prvCheck( "li a0, 42; ret", prvRun( aulFortyTwo, 2 ), 42u );
    iPass &= prvCheck( "lui a0, 0x12345; addi a0, a0, 0x678; ret", prvRun( aulLarge, 3 ), 0x12345678u );

    app_printf( "selfmod: %s\n", iPass ? "PASS" : "FAIL" );
    return iPass ? 0 : 1;
}
