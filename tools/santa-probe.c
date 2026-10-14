/* Disposable Santa execution-control probe. It intentionally has no side effects. */
#ifndef CHICKENBLOCKER_PROBE_NONCE
#define CHICKENBLOCKER_PROBE_NONCE "development"
#endif

__attribute__((used)) static const char probe_nonce[] = CHICKENBLOCKER_PROBE_NONCE;

int main(void) { return 0; }
