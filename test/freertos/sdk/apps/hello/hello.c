/* hello.c -- the smallest useful app: a greeting and the arguments it was run with.
 *
 *   hades> run world 42
 *   Hello, world!
 *   argv[0] = hello
 *   argv[1] = world
 *   argv[2] = 42
 *   app: hello exited with code 2 after ... cycles
 *
 * Without arguments it greets HaDes-V+. The exit code is the number of arguments. */
#include "hades_app.h"

int main( int argc, char ** argv )
{
    app_printf( "Hello, %s!\n", ( argc > 1 ) ? argv[ 1 ] : "HaDes-V+" );

    for( int i = 0; i < argc; i++ )
    {
        app_printf( "argv[%d] = %s\n", i, argv[ i ] );
    }

    return argc - 1;
}
