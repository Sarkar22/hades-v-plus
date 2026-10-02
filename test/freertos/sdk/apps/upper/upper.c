/* upper.c -- an app that reads the terminal: it converts lines to upper case.
 *
 *   hades> run
 *   upper: type lines; an empty line ends
 *   > hello world
 *   HELLO WORLD
 *   >
 *   app: upper exited with code 1 after ... cycles
 *
 * app_getc() returns the bytes as they are typed: the app echoes them itself, handles
 * Backspace and DEL, and ends a line at CR or LF (CR LF counts once). Ctrl-C never arrives:
 * it stops the app. The exit code is the number of lines converted. */
#include <stdint.h>
#include "hades_app.h"

#define UPPER_LINE_MAX    80

int main( void )
{
    char acLine[ UPPER_LINE_MAX + 1 ];
    uint32_t ulLength = 0;
    int iLines = 0, iPrevious = 0;

    app_puts( "upper: type lines; an empty line ends\n> " );

    for( ; ; )
    {
        const int c = app_getc( -1 );

        if( ( c == '\n' ) && ( iPrevious == '\r' ) )
        {
            iPrevious = c;   /* the LF of CR LF */
            continue;
        }

        iPrevious = c;

        if( ( c == '\r' ) || ( c == '\n' ) )
        {
            app_putc( '\n' );

            if( ulLength == 0 )
            {
                return iLines;
            }

            for( uint32_t i = 0; i < ulLength; i++ )
            {
                if( ( acLine[ i ] >= 'a' ) && ( acLine[ i ] <= 'z' ) )
                {
                    acLine[ i ] = ( char ) ( acLine[ i ] - 'a' + 'A' );
                }
            }

            acLine[ ulLength ] = '\0';
            app_printf( "%s\n> ", acLine );
            ulLength = 0;
            iLines++;
        }
        else if( ( c == '\b' ) || ( c == 0x7F ) )
        {
            if( ulLength > 0 )
            {
                ulLength--;
                app_puts( "\b \b" );
            }
        }
        else if( ( c >= ' ' ) && ( c <= '~' ) && ( ulLength < UPPER_LINE_MAX ) )
        {
            acLine[ ulLength++ ] = ( char ) c;
            app_putc( ( char ) c );
        }
    }
}
