#ifndef LOCAL_WHISPER_CORE_H
#define LOCAL_WHISPER_CORE_H
char *lw_call(const char *request);
void lw_free(char *response);
void lw_shutdown(void);
#endif
