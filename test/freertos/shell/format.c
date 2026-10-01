/* format.c -- shell_snprintf(), a small bounded formatter for the shell.
 *
 * The program image has no stdio (newlib's printf family would pull in several
 * kilobytes and its reentrancy data), so the shell formats its output with this.
 * Supported: %d %i %u %x %X %s %c %%, the flags '-' (left-justify) and '0'
 * (zero-pad), a field width given as digits or '*', a precision for %s ('.' and
 * digits or '*': at most that many characters), and the length modifiers 'l' and
 * 'z' (32 bits on RV32) and 'll' (64 bits). An unsupported conversion is copied to
 * the output as it stands.
 */
#include "shell.h"

typedef struct
{
    char * pcBuf;
    size_t xSize;   /* capacity including the terminator */
    size_t xPos;    /* characters stored so far */
} Out_t;

static void prvPut( Out_t * pxOut, char c )
{
    if( ( pxOut->xPos + 1u ) < pxOut->xSize )
    {
        pxOut->pcBuf[ pxOut->xPos ] = c;
        pxOut->xPos++;
    }
}

static void prvPad( Out_t * pxOut, char c, int iCount )
{
    while( iCount-- > 0 )
    {
        prvPut( pxOut, c );
    }
}

/* Writes one field: an optional sign, then the digits, justified in iWidth. */
static void prvField( Out_t * pxOut, const char * pcDigits, int iLen, char cSign, int iWidth, int iLeft, int iZero )
{
    int iPad = iWidth - iLen - ( ( cSign != '\0' ) ? 1 : 0 );

    if( ( iLeft == 0 ) && ( iZero == 0 ) )
    {
        prvPad( pxOut, ' ', iPad );
    }

    if( cSign != '\0' )
    {
        prvPut( pxOut, cSign );
    }

    if( ( iLeft == 0 ) && ( iZero != 0 ) )
    {
        prvPad( pxOut, '0', iPad );
    }

    for( int i = 0; i < iLen; i++ )
    {
        prvPut( pxOut, pcDigits[ i ] );
    }

    if( iLeft != 0 )
    {
        prvPad( pxOut, ' ', iPad );
    }
}

/* 64-bit unsigned division by shift and subtract. It keeps libgcc's 64-bit
 * division (__udivdi3 and __umoddi3, 2.7 KiB) out of the 32 KiB image; values that
 * fit in 32 bits take the 32-bit path. */
uint64_t shell_udiv64( uint64_t ullN, uint64_t ullD, uint64_t * pullRem )
{
    uint64_t q = 0, r = 0;

    if( ( ( ullN | ullD ) >> 32 ) == 0u )
    {
        q = ( uint32_t ) ullN / ( uint32_t ) ullD;
        r = ( uint32_t ) ullN % ( uint32_t ) ullD;
    }
    else
    {
        for( int i = 63; i >= 0; i-- )
        {
            const uint64_t ullCarry = r >> 63;

            r = ( r << 1 ) | ( ( ullN >> i ) & 1u );

            if( ( ullCarry != 0u ) || ( r >= ullD ) )
            {
                r -= ullD;
                q |= ( uint64_t ) 1u << i;
            }
        }
    }

    if( pullRem != NULL )
    {
        *pullRem = r;
    }

    return q;
}

/* Unsigned 64-bit value to digits in base 10 or 16, most significant first. */
static int prvDigits( char * pcOut, uint64_t ullValue, unsigned uBase, int iUpper )
{
    const char * pcSet = ( iUpper != 0 ) ? "0123456789ABCDEF" : "0123456789abcdef";
    char acTmp[ 20 ];
    int n = 0;

    while( ( ullValue >> 32 ) != 0u )
    {
        uint64_t ullDigit;

        ullValue = shell_udiv64( ullValue, uBase, &ullDigit );
        acTmp[ n++ ] = pcSet[ ullDigit ];
    }

    for( uint32_t ulValue = ( uint32_t ) ullValue; ; )
    {
        acTmp[ n++ ] = pcSet[ ulValue % uBase ];
        ulValue /= uBase;

        if( ulValue == 0u )
        {
            break;
        }
    }

    for( int i = 0; i < n; i++ )
    {
        pcOut[ i ] = acTmp[ n - 1 - i ];
    }

    return n;
}

int shell_vsnprintf( char * pcBuffer, size_t xSize, const char * pcFormat, va_list xArgs )
{
    Out_t xOut = { pcBuffer, xSize, 0 };

    if( xSize == 0u )
    {
        return 0;
    }

    for( const char * p = pcFormat; *p != '\0'; p++ )
    {
        int iLeft = 0, iZero = 0, iWidth = 0, iLong = 0, iPrecision = -1;
        const char * pcStart = p;

        if( *p != '%' )
        {
            prvPut( &xOut, *p );
            continue;
        }

        p++;

        for( ; ; p++ )   /* flags */
        {
            if( *p == '-' )
            {
                iLeft = 1;
            }
            else if( *p == '0' )
            {
                iZero = 1;
            }
            else
            {
                break;
            }
        }

        if( *p == '*' )   /* width */
        {
            iWidth = va_arg( xArgs, int );

            if( iWidth < 0 )
            {
                iLeft = 1;
                iWidth = -iWidth;
            }

            p++;
        }
        else
        {
            while( ( *p >= '0' ) && ( *p <= '9' ) )
            {
                iWidth = ( iWidth * 10 ) + ( *p - '0' );
                p++;
            }
        }

        if( *p == '.' )   /* precision */
        {
            p++;
            iPrecision = 0;

            if( *p == '*' )
            {
                iPrecision = va_arg( xArgs, int );
                p++;
            }
            else
            {
                while( ( *p >= '0' ) && ( *p <= '9' ) )
                {
                    iPrecision = ( iPrecision * 10 ) + ( *p - '0' );
                    p++;
                }
            }
        }

        if( *p == 'z' )   /* length */
        {
            p++;
        }
        else if( *p == 'l' )
        {
            p++;

            if( *p == 'l' )
            {
                iLong = 1;
                p++;
            }
        }

        switch( *p )
        {
            case 'd':
            case 'i':
               {
                   char acDigits[ 20 ];
                   int64_t llValue = ( iLong != 0 ) ? va_arg( xArgs, int64_t ) : ( int64_t ) va_arg( xArgs, int32_t );
                   uint64_t ullMagnitude = ( llValue < 0 ) ? ( ( uint64_t ) 0 - ( uint64_t ) llValue ) : ( uint64_t ) llValue;
                   int n = prvDigits( acDigits, ullMagnitude, 10u, 0 );
                   prvField( &xOut, acDigits, n, ( llValue < 0 ) ? '-' : '\0', iWidth, iLeft, iZero );
                   break;
               }

            case 'u':
            case 'x':
            case 'X':
               {
                   char acDigits[ 20 ];
                   uint64_t ullValue = ( iLong != 0 ) ? va_arg( xArgs, uint64_t ) : ( uint64_t ) va_arg( xArgs, uint32_t );
                   int n = prvDigits( acDigits, ullValue, ( *p == 'u' ) ? 10u : 16u, *p == 'X' );
                   prvField( &xOut, acDigits, n, '\0', iWidth, iLeft, iZero );
                   break;
               }

            case 's':
               {
                   const char * s = va_arg( xArgs, const char * );
                   int n = 0;

                   if( s == NULL )
                   {
                       s = "(null)";
                   }

                   while( ( s[ n ] != '\0' ) && ( ( iPrecision < 0 ) || ( n < iPrecision ) ) )
                   {
                       n++;
                   }

                   prvField( &xOut, s, n, '\0', iWidth, iLeft, 0 );
                   break;
               }

            case 'c':
               {
                   char c = ( char ) va_arg( xArgs, int );
                   prvField( &xOut, &c, 1, '\0', iWidth, iLeft, 0 );
                   break;
               }

            case '%':
                prvPut( &xOut, '%' );
                break;

            default:   /* unsupported, or the string ended: copy it as it stands */
                while( ( pcStart <= p ) && ( *pcStart != '\0' ) )
                {
                    prvPut( &xOut, *pcStart++ );
                }

                if( *p == '\0' )
                {
                    p--;
                }

                break;
        }
    }

    pcBuffer[ xOut.xPos ] = '\0';
    return ( int ) xOut.xPos;
}

int shell_snprintf( char * pcBuffer, size_t xSize, const char * pcFormat, ... )
{
    va_list xArgs;
    int n;

    va_start( xArgs, pcFormat );
    n = shell_vsnprintf( pcBuffer, xSize, pcFormat, xArgs );
    va_end( xArgs );
    return n;
}
