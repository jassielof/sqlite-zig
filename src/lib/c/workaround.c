#include "workaround.h"

sqlite3_destructor_type sqliteTransientAsDestructor(void) {
    return (sqlite3_destructor_type)-1;
}
