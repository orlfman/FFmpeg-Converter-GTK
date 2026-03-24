#include <gio/gio.h>

GSubprocess *
ffcg_subprocess_launcher_spawnv_compat (GSubprocessLauncher *launcher,
                                        gchar **argv,
                                        GError **error)
{
    return g_subprocess_launcher_spawnv (
        launcher,
        (const gchar * const *) argv,
        error
    );
}
