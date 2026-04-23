/*
 * alphasound-splash — minimal boot splash for Pirate Audio LCD.
 *
 * Runs from the openrc boot runlevel, long before shairport-sync and
 * the Python display service are ready. Paints a static RGB565 splash
 * image (generated at build time by gen-splash.py) to the ST7789
 * panel so the user doesn't stare at a dark screen during boot.
 *
 * Hardware assumptions:
 *   BCM2835-compatible GPIO (Pi Zero 2 W / 3 / 4)
 *   SPI0 enabled (dtparam=spi=on in usercfg.txt)
 *   Pirate Audio wiring: SPI CE1, DC = GPIO 9, BL = GPIO 13, 240x240
 *
 * Intentionally self-contained: no libpthread, no libgpiod, no SPI
 * Python — just /dev/gpiomem + /dev/spidev0.1 + raw syscalls so the
 * binary starts painting ~500ms after the kernel finishes sysinit,
 * not 2-3s later like the Python equivalent.
 */

#define _DEFAULT_SOURCE
#include <fcntl.h>
#include <linux/spi/spidev.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

#define WIDTH      240
#define HEIGHT     240
#define PIXELS     (WIDTH * HEIGHT)
#define DC_PIN     9
#define BL_PIN     13
#define SPI_DEV    "/dev/spidev0.1"
#define GPIOMEM    "/dev/gpiomem"
#define SPLASH_RAW "/usr/share/alphasound-splash/splash.raw"

/* BCM2835 GPIO register indices (as uint32_t*, so byte-offset / 4). */
#define GPFSEL0    0     /* 0x00: pins 0-9, 3 bits per pin */
#define GPFSEL1    1     /* 0x04: pins 10-19              */
#define GPSET0     7     /* 0x1C                          */
#define GPCLR0     10    /* 0x28                          */

static volatile uint32_t *gpio;
static int spi_fd;

static void gpio_out(int pin) {
    int reg = pin / 10;
    int shift = (pin % 10) * 3;
    uint32_t v = gpio[reg];
    v &= ~(0x7u << shift);
    v |= (0x1u << shift);           /* 0b001 = output */
    gpio[reg] = v;
}

static void gpio_set(int pin, int high) {
    gpio[high ? GPSET0 : GPCLR0] = 1u << pin;
}

static void sleep_ms(int ms) {
    struct timespec ts = { ms / 1000, (long)(ms % 1000) * 1000000L };
    nanosleep(&ts, NULL);
}

static void spi_write(const uint8_t *buf, size_t len) {
    while (len > 0) {
        size_t chunk = len > 4096 ? 4096 : len;
        ssize_t n = write(spi_fd, buf, chunk);
        if (n <= 0) return;
        buf += n;
        len -= (size_t)n;
    }
}

static void cmd(uint8_t c) {
    gpio_set(DC_PIN, 0);
    spi_write(&c, 1);
}

static void data(const uint8_t *d, size_t len) {
    gpio_set(DC_PIN, 1);
    spi_write(d, len);
}

static void data1(uint8_t d) { data(&d, 1); }

int main(void) {
    int mem_fd = open(GPIOMEM, O_RDWR | O_SYNC);
    if (mem_fd < 0) { perror("open " GPIOMEM); return 1; }
    gpio = mmap(NULL, 4096, PROT_READ | PROT_WRITE, MAP_SHARED, mem_fd, 0);
    if (gpio == MAP_FAILED) { perror("mmap"); close(mem_fd); return 1; }
    close(mem_fd);

    gpio_out(DC_PIN);
    gpio_out(BL_PIN);
    gpio_set(BL_PIN, 1);

    spi_fd = open(SPI_DEV, O_RDWR);
    if (spi_fd < 0) { perror("open " SPI_DEV); return 1; }
    uint8_t spi_mode = 0;
    uint32_t speed = 32000000u;
    ioctl(spi_fd, SPI_IOC_WR_MODE, &spi_mode);
    ioctl(spi_fd, SPI_IOC_WR_MAX_SPEED_HZ, &speed);

    /* ST7789 init with Pimoroni gamma/VCOM/porch tuning — matches the
     * Python driver so the handoff to alphasound-display later doesn't
     * visibly re-tune the panel. */
    cmd(0x01); sleep_ms(150);          /* SWRESET              */
    cmd(0x11); sleep_ms(120);          /* SLPOUT               */
    cmd(0x36); data1(0x00);            /* MADCTL               */
    cmd(0x3A); data1(0x55);            /* COLMOD RGB565        */

    { uint8_t d[] = {0x0C,0x0C,0x00,0x33,0x33};
      cmd(0xB2); data(d, sizeof d); }  /* PORCTRL              */
    cmd(0xB7); data1(0x35);            /* GCTRL                */
    cmd(0xBB); data1(0x19);            /* VCOMS                */
    cmd(0xC0); data1(0x2C);            /* LCMCTRL              */
    cmd(0xC2); data1(0x01);            /* VDVVRHEN             */
    cmd(0xC3); data1(0x12);            /* VRHS                 */
    cmd(0xC4); data1(0x20);            /* VDVS                 */
    cmd(0xC6); data1(0x0F);            /* FRCTRL2 60 Hz        */
    { uint8_t d[] = {0xA4,0xA1};
      cmd(0xD0); data(d, sizeof d); }  /* PWCTRL1              */
    { uint8_t d[] = {0xD0,0x04,0x0D,0x11,0x13,0x2B,0x3F,0x54,0x4C,
                     0x18,0x0D,0x0B,0x1F,0x23};
      cmd(0xE0); data(d, sizeof d); }  /* PVGAMCTRL            */
    { uint8_t d[] = {0xD0,0x04,0x0C,0x11,0x13,0x2C,0x3F,0x44,0x51,
                     0x2F,0x1F,0x1F,0x20,0x23};
      cmd(0xE1); data(d, sizeof d); }  /* NVGAMCTRL            */

    cmd(0x21);                         /* INVON                */
    cmd(0x13);                         /* NORON                */
    cmd(0x29); sleep_ms(50);           /* DISPON               */

    /* Full-panel window */
    { uint8_t d[] = {0, 0, 0, WIDTH - 1};
      cmd(0x2A); data(d, sizeof d); }  /* CASET                */
    { uint8_t d[] = {0, 0, 0, HEIGHT - 1};
      cmd(0x2B); data(d, sizeof d); }  /* RASET                */

    int raw_fd = open(SPLASH_RAW, O_RDONLY);
    if (raw_fd < 0) { perror("open " SPLASH_RAW); return 1; }

    static uint8_t pixels[PIXELS * 2];
    ssize_t got = read(raw_fd, pixels, sizeof pixels);
    close(raw_fd);
    if (got != (ssize_t)sizeof pixels) {
        fprintf(stderr, "splash size mismatch: got %zd, want %zu\n",
                got, sizeof pixels);
        return 1;
    }

    cmd(0x2C);                          /* RAMWR                */
    data(pixels, sizeof pixels);

    close(spi_fd);
    return 0;
}
