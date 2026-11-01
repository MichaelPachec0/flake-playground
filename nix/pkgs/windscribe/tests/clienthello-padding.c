/*
 * Regression check for the Windscribe super-large TLS padding patch: build a
 * ClientHello into a memory BIO with and without SSL_OP_TLSEXT_PADDING_SUPER
 * and compare sizes. The patch adds a 7000-9999 byte extension, so a padded
 * hello must be at least 7000 bytes larger than a plain one. Catches the patch
 * compiling but never firing (e.g. a gate on a flag upstream made a no-op).
 */
#include <stdio.h>
#include <openssl/ssl.h>

static long hello_len(SSL_CTX *ctx)
{
    SSL *ssl = SSL_new(ctx);
    BIO *rbio = BIO_new(BIO_s_mem());
    BIO *wbio = BIO_new(BIO_s_mem());
    long n;

    SSL_set_bio(ssl, rbio, wbio);
    SSL_set_connect_state(ssl);
    SSL_set_tlsext_host_name(ssl, "example.com");
    SSL_do_handshake(ssl); /* stops at WANT_READ after writing the hello */
    n = (long)BIO_ctrl_pending(wbio);
    SSL_free(ssl);
    return n;
}

int main(void)
{
    SSL_CTX *ctx = SSL_CTX_new(TLS_client_method());
    long plain, padded;

    plain = hello_len(ctx);
    SSL_CTX_set_options(ctx, SSL_OP_TLSEXT_PADDING_SUPER);
    padded = hello_len(ctx);
    SSL_CTX_free(ctx);

    printf("[opensslEch] ClientHello plain=%ld padded=%ld\n", plain, padded);
    if (plain <= 0 || padded - plain < 7000) {
        fprintf(stderr, "ERROR: super-large TLS padding not applied\n");
        return 1;
    }
    return 0;
}
