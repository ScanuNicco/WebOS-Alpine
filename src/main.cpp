#define SDL_MAIN_HANDLED

#include <SDL.h>

#include <cstdio>
#include <algorithm>
#include <cstdlib>
#include <cstdint>
#include <cstring>
#include <string>
#include <vector>

#include <unistd.h>
#include <errno.h>
#include <netdb.h>
#include <sys/socket.h>
#include <sys/select.h>

static bool recvExact(int fd, void *buffer, size_t length)
{
    uint8_t *p = static_cast<uint8_t *>(buffer);

    while (length > 0) {
        ssize_t n = recv(fd, p, length, 0);

        if (n < 0 && errno == EINTR)
            continue;

        if (n <= 0)
            return false;

        p += n;
        length -= n;
    }

    return true;
}

static bool sendExact(int fd, const void *buffer, size_t length)
{
    const uint8_t *p = static_cast<const uint8_t *>(buffer);

    while (length > 0) {
        ssize_t n = send(fd, p, length, 0);

        if (n < 0 && errno == EINTR)
            continue;

        if (n <= 0)
            return false;

        p += n;
        length -= n;
    }

    return true;
}

static bool sendPointerEvent(int fd, uint8_t buttons, uint16_t x, uint16_t y)
{
    uint8_t msg[6] = {
        5,                          // PointerEvent
        buttons,
        static_cast<uint8_t>(x >> 8),
        static_cast<uint8_t>(x),
        static_cast<uint8_t>(y >> 8),
        static_cast<uint8_t>(y)
    };

    return sendExact(fd, msg, sizeof(msg));
}

static uint16_t readU16(const uint8_t *p)
{
    return (uint16_t(p[0]) << 8) | p[1];
}

static uint32_t readU32(const uint8_t *p)
{
    return (uint32_t(p[0]) << 24) |
           (uint32_t(p[1]) << 16) |
           (uint32_t(p[2]) << 8) |
           uint32_t(p[3]);
}

static void writeU16(uint8_t *p, uint16_t v)
{
    p[0] = uint8_t(v >> 8);
    p[1] = uint8_t(v);
}

static void writeU32(uint8_t *p, uint32_t v)
{
    p[0] = uint8_t(v >> 24);
    p[1] = uint8_t(v >> 16);
    p[2] = uint8_t(v >> 8);
    p[3] = uint8_t(v);
}

static int connectToServer(const char *host, const char *port)
{
    struct addrinfo hints = {};
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;

    struct addrinfo *results = nullptr;

    int error = getaddrinfo(host, port, &hints, &results);

    if (error != 0) {
        fprintf(stderr, "getaddrinfo: %s\n", gai_strerror(error));
        return -1;
    }

    int fd = -1;

    for (struct addrinfo *p = results; p; p = p->ai_next) {
        fd = socket(p->ai_family, p->ai_socktype, p->ai_protocol);

        if (fd < 0)
            continue;

        if (connect(fd, p->ai_addr, p->ai_addrlen) == 0)
            break;

        close(fd);
        fd = -1;
    }

    freeaddrinfo(results);

    if (fd < 0)
        perror("VNC connection failed");

    return fd;
}

static bool readLengthPrefixedReason(int fd)
{
    uint8_t lengthBytes[4];

    if (!recvExact(fd, lengthBytes, 4))
        return false;

    uint32_t length = readU32(lengthBytes);

    if (length > 65536)
        return false;

    std::vector<char> reason(length + 1);

    if (!recvExact(fd, reason.data(), length))
        return false;

    reason[length] = '\0';

    fprintf(stderr, "VNC server rejected connection: %s\n",
            reason.data());

    return false;
}

static bool handshake(int fd, int &width, int &height)
{
    char serverVersion[12];

    if (!recvExact(fd, serverVersion, sizeof(serverVersion))) {
        fprintf(stderr, "Failed to read server version\n");
        return false;
    }

    printf("Server version: %.*s", 12, serverVersion);

    int major = 0;
    int minor = 0;

    if (sscanf(serverVersion, "RFB %03d.%03d", &major, &minor) != 2 ||
        major != 3 || minor < 8) {
        fprintf(stderr, "This test client requires RFB 3.8\n");
        return false;
    }

    const char clientVersion[] = "RFB 003.008\n";

    if (!sendExact(fd, clientVersion, 12))
        return false;

    // Read security type count.
    uint8_t count;

    if (!recvExact(fd, &count, 1))
        return false;

    if (count == 0)
        return readLengthPrefixedReason(fd);

    if (count > 64)
        return false;

    std::vector<uint8_t> types(count);

    if (!recvExact(fd, types.data(), types.size()))
        return false;

    bool supportsNone = false;

    for (uint8_t type : types) {
        printf("Security type offered: %u\n", type);
        if (type == 1)
            supportsNone = true;
    }

    if (!supportsNone) {
        fprintf(stderr,
                "Server does not offer unauthenticated access (None).\n");
        return false;
    }

    // Select security type None.
    const uint8_t none = 1;

    if (!sendExact(fd, &none, 1))
        return false;

    uint8_t securityResult[4];

    if (!recvExact(fd, securityResult, 4))
        return false;

    if (readU32(securityResult) != 0) {
        fprintf(stderr, "VNC security negotiation failed\n");
        return false;
    }

    // ClientInit: shared connection.
    const uint8_t shared = 1;

    if (!sendExact(fd, &shared, 1))
        return false;

    // ServerInit fixed portion.
    uint8_t init[24];

    if (!recvExact(fd, init, sizeof(init)))
        return false;

    printf("ServerInit raw bytes:");
    for (int i = 0; i < 24; ++i)
        printf(" %02x", init[i]);
    printf("\n");
    
    printf("ServerInit dimensions bytes: %02x %02x %02x %02x\n",
           init[0], init[1], init[2], init[3]);
    fflush(stdout);

    //width = readU16(init);
    //height = readU16(init);
	width  = (uint16_t(init[0]) << 8) | init[1];
	height = (uint16_t(init[2]) << 8) | init[3];
	
	printf("Direct parse: %u x %u\n", width, height);
	printf("Individual height bytes: %u %u\n", init[2], init[3]);
	fflush(stdout);

    printf("Parsed framebuffer dimensions: %u x %u\n", width, height);
    fflush(stdout);

    if (width == 0 || height == 0 ||
        width > 16384 || height > 16384) {
        fprintf(stderr, "Invalid framebuffer dimensions\n");
        return false;
    }

    uint32_t nameLength = readU32(init + 20);

    if (nameLength > 65536)
        return false;

    std::vector<char> name(nameLength + 1);

    if (!recvExact(fd, name.data(), nameLength))
        return false;

    name[nameLength] = '\0';

    printf("Connected to: %s\n", name.data());
    printf("Framebuffer: %dx%d\n", width, height);

    // SetPixelFormat: 32 bpp, 24-bit depth, little endian,
    // true color, RGB shifts 16/8/0.
    uint8_t pixelFormat[20] = {};

    pixelFormat[0] = 0;       // SetPixelFormat
    pixelFormat[4] = 32;      // Bits per pixel
    pixelFormat[5] = 24;      // Depth
    pixelFormat[6] = 0;       // Big endian
    pixelFormat[7] = 1;       // True color

    writeU16(pixelFormat + 8, 255);
    writeU16(pixelFormat + 10, 255);
    writeU16(pixelFormat + 12, 255);

    pixelFormat[14] = 16;     // Red shift
    pixelFormat[15] = 8;      // Green shift
    pixelFormat[16] = 0;      // Blue shift

    if (!sendExact(fd, pixelFormat, sizeof(pixelFormat)))
        return false;

    // SetEncodings: Raw only.
    uint8_t encodings[8] = {};

    encodings[0] = 2;
    writeU16(encodings + 2, 1);
    writeU32(encodings + 4, 0);

    if (!sendExact(fd, encodings, sizeof(encodings)))
        return false;

    return true;
}

static bool requestFramebuffer(int fd, int width, int height,
                               bool incremental)
{
    uint8_t request[10] = {};

    request[0] = 3;
    request[1] = incremental ? 1 : 0;

    writeU16(request + 2, 0);
    writeU16(request + 4, 0);
    writeU16(request + 6, uint16_t(width));
    writeU16(request + 8, uint16_t(height));

    return sendExact(fd, request, sizeof(request));
}

static bool drawRectangle(
    int fd,
    SDL_Surface *framebuffer,
    int x, int y, int width, int height)
{
    if (x < 0 || y < 0 ||
        width < 0 || height < 0 ||
        x + width > framebuffer->w ||
        y + height > framebuffer->h) {
        fprintf(stderr, "Invalid framebuffer rectangle\n");
        return false;
    }

    size_t bytes = size_t(width) * size_t(height) * 4;

    if (bytes > 256 * 1024 * 1024) {
        fprintf(stderr, "Framebuffer rectangle too large\n");
        return false;
    }

    std::vector<uint8_t> raw(bytes);

    if (!recvExact(fd, raw.data(), bytes))
        return false;

    if (SDL_LockSurface(framebuffer) != 0) {
        fprintf(stderr, "SDL_LockSurface: %s\n", SDL_GetError());
        return false;
    }

    for (int row = 0; row < height; ++row) {
        uint32_t *dst = reinterpret_cast<uint32_t *>(
            static_cast<uint8_t *>(framebuffer->pixels) +
            (y + row) * framebuffer->pitch
        );

        const uint8_t *src =
            raw.data() + size_t(row) * width * 4;

        for (int col = 0; col < width; ++col) {
            uint8_t blue  = src[col * 4 + 0];
            uint8_t green = src[col * 4 + 1];
            uint8_t red   = src[col * 4 + 2];

            dst[x + col] =
                0xFF000000u |
                (uint32_t(red) << 16) |
                (uint32_t(green) << 8) |
                uint32_t(blue);
        }
    }

    SDL_UnlockSurface(framebuffer);

    return true;
}

static bool processFramebufferUpdate(
    int fd,
    SDL_Surface *framebuffer,
    SDL_Window *window)
{
    uint8_t header[3];

    if (!recvExact(fd, header, sizeof(header)))
        return false;

    uint16_t rectCount = readU16(header + 1);

    for (unsigned i = 0; i < rectCount; ++i) {
        uint8_t rect[12];

        if (!recvExact(fd, rect, sizeof(rect)))
            return false;

        int x = readU16(rect);
        int y = readU16(rect + 2);
        int w = readU16(rect + 4);
        int h = readU16(rect + 6);
        int32_t encoding = static_cast<int32_t>(readU32(rect + 8));

        if (encoding != 0) {
            fprintf(stderr, "Unsupported encoding: %d\n", encoding);
            return false;
        }

        if (!drawRectangle(fd, framebuffer, x, y, w, h))
            return false;
    }

    SDL_Surface *windowSurface = SDL_GetWindowSurface(window);

    if (!windowSurface)
        return false;

    printf("Framebuffer surface: %dx%d\n",
           framebuffer->w, framebuffer->h);
    
    printf("Window surface: %dx%d\n",
           windowSurface->w, windowSurface->h);
    
    int windowW, windowH;
    SDL_GetWindowSize(window, &windowW, &windowH);
    
    printf("SDL window: %dx%d\n", windowW, windowH);
    fflush(stdout);

    if (SDL_BlitScaled(framebuffer, nullptr,
                       windowSurface, nullptr) != 0) {
        fprintf(stderr, "SDL_BlitScaled: %s\n", SDL_GetError());
        return false;
    }

    if (SDL_UpdateWindowSurface(window) != 0) {
        fprintf(stderr, "SDL_UpdateWindowSurface: %s\n", SDL_GetError());
        return false;
    }

    return true;
}

static bool processServerMessage(
    int fd,
    SDL_Surface *framebuffer,
    SDL_Window *window)
{
    uint8_t type;

    if (!recvExact(fd, &type, 1))
        return false;

    switch (type) {
    case 0:
        if (!processFramebufferUpdate(fd, framebuffer, window))
            return false;

        return requestFramebuffer(
            fd, framebuffer->w, framebuffer->h, true);

    case 1: {
        // SetColourMapEntries.
        uint8_t header[5];

        if (!recvExact(fd, header, sizeof(header)))
            return false;

        uint16_t count = readU16(header + 3);
        size_t bytes = size_t(count) * 6;

        std::vector<uint8_t> ignored(bytes);

        return recvExact(fd, ignored.data(), bytes);
    }

    case 2:
        // Bell.
        printf("Server bell\n");
        return true;

    case 3: {
        // ServerCutText.
        uint8_t header[7];

        if (!recvExact(fd, header, sizeof(header)))
            return false;

        uint32_t length = readU32(header + 3);

        if (length > 16 * 1024 * 1024)
            return false;

        std::vector<uint8_t> ignored(length);

        return recvExact(fd, ignored.data(), length);
    }

    default:
        fprintf(stderr, "Unknown server message type: %u\n", type);
        return false;
    }
}

int main(int argc, char *argv[])
{
	int argOffset = 1;

	// Skip webOS launch metadata.
	if (argc > 1 && argv[1][0] == '{')
	    argOffset = 2;

	int appArgc = argc - argOffset;

	if (appArgc < 1 || appArgc > 2) {
	    printf("Usage: %s <server-address> [port]\n", argv[0]);
	    return 1;
	}

	const char *host = argv[argOffset];
	const char *port = appArgc == 2 ? argv[argOffset + 1] : "5900";

	printf("Connecting to %s:%s\n", host, port);
	fflush(stdout);

	int fd = connectToServer(host, port);

    if (fd < 0)
        return 1;

    int remoteWidth = 0;
    int remoteHeight = 0;

    if (!handshake(fd, remoteWidth, remoteHeight)) {
        close(fd);
        return 1;
    }

    SDL_SetMainReady();

    if (SDL_Init(
        SDL_INIT_TIMER |
        SDL_INIT_VIDEO |
        SDL_INIT_EVENTS
    ) < 0) {
        fprintf(stderr, "SDL_Init: %s\n", SDL_GetError());
        close(fd);
        return 1;
    }

    SDL_DisplayMode mode = {};

    if (SDL_GetCurrentDisplayMode(0, &mode) != 0) {
        mode.w = 1280;
        mode.h = 720;
    }

    printf("SDL display mode: %dx%d\n", mode.w, mode.h);
    fflush(stdout);

    SDL_Window *window = SDL_CreateWindow(
        "TigerVNC webOS test",
        SDL_WINDOWPOS_UNDEFINED,
        SDL_WINDOWPOS_UNDEFINED,
        mode.w,
        mode.h,
        SDL_WINDOW_FULLSCREEN
    );

    if (!window) {
        fprintf(stderr, "SDL_CreateWindow: %s\n", SDL_GetError());
        SDL_Quit();
        close(fd);
        return 1;
    }

    SDL_Surface *framebuffer = SDL_CreateRGBSurfaceWithFormat(
        0, remoteWidth, remoteHeight, 32, SDL_PIXELFORMAT_ARGB8888
    );

    if (!framebuffer) {
        fprintf(stderr, "Framebuffer allocation: %s\n", SDL_GetError());
        SDL_DestroyWindow(window);
        SDL_Quit();
        close(fd);
        return 1;
    }

    SDL_FillRect(framebuffer, nullptr,
                 SDL_MapRGB(framebuffer->format, 0, 0, 0));

    if (!requestFramebuffer(fd, remoteWidth, remoteHeight, false)) {
        fprintf(stderr, "Initial framebuffer request failed\n");
        SDL_FreeSurface(framebuffer);
        SDL_DestroyWindow(window);
        SDL_Quit();
        close(fd);
        return 1;
    }

    printf("Waiting for framebuffer updates...\n");
    fflush(stdout);

    bool running = true;
    bool connected = true;

	uint8_t mouseButtons = 0;
	int mouseX = 0;
	int mouseY = 0;

	int windowW, windowH;
	SDL_GetWindowSize(window, &windowW, &windowH);

    while (running && connected) {
        SDL_Event event;

        while (SDL_PollEvent(&event)) {
            if (event.type == SDL_QUIT)
                running = false;

            if (event.type == SDL_KEYDOWN &&
                (event.key.keysym.sym == SDLK_ESCAPE ||
                 event.key.keysym.sym == SDLK_q))
                running = false;

            if (event.type == SDL_KEYDOWN || event.type == SDL_KEYUP) {
                printf("KEY %s: scancode=%d keycode=%d mod=%u\n",
                       event.type == SDL_KEYDOWN ? "DOWN" : "UP",
                       event.key.keysym.scancode,
                       event.key.keysym.sym,
                       event.key.keysym.mod);
                fflush(stdout);
            }
            
            if (event.type == SDL_MOUSEMOTION) {
                printf("MOUSE MOVE: x=%d y=%d\n",
                       event.motion.x, event.motion.y);
                fflush(stdout);
            }
            
            if (event.type == SDL_MOUSEMOTION ||
                event.type == SDL_MOUSEBUTTONDOWN ||
                event.type == SDL_MOUSEBUTTONUP) {
            
                int x, y;
            
                if (event.type == SDL_MOUSEMOTION) {
                    x = event.motion.x;
                    y = event.motion.y;
                } else {
                    x = event.button.x;
                    y = event.button.y;
                }
            
                mouseX = x * remoteWidth / windowW;
                mouseY = y * remoteHeight / windowH;
            
                mouseX = std::max(0, std::min(mouseX, remoteWidth - 1));
                mouseY = std::max(0, std::min(mouseY, remoteHeight - 1));
            
                if (event.type == SDL_MOUSEBUTTONDOWN ||
                    event.type == SDL_MOUSEBUTTONUP) {
            
                    uint8_t buttonMask = 0;
            
                    switch (event.button.button) {
                        case SDL_BUTTON_LEFT:   buttonMask = 1; break;
                        case SDL_BUTTON_MIDDLE: buttonMask = 2; break;
                        case SDL_BUTTON_RIGHT:  buttonMask = 4; break;
                    }
            
                    if (event.type == SDL_MOUSEBUTTONDOWN)
                        mouseButtons |= buttonMask;
                    else
                        mouseButtons &= ~buttonMask;
                }
            
                if (!sendPointerEvent(fd, mouseButtons, mouseX, mouseY))
                    running = false;
            }
            
            if (event.type == SDL_MOUSEWHEEL) {
                int direction = event.wheel.y;
            
                if (event.wheel.direction == SDL_MOUSEWHEEL_FLIPPED)
                    direction = -direction;
            
                uint8_t wheelButton = direction > 0 ? 8 : 16;
            
                for (int i = 0; i < std::abs(direction); ++i) {
                    if (!sendPointerEvent(fd, mouseButtons | wheelButton,
                                          mouseX, mouseY) ||
                        !sendPointerEvent(fd, mouseButtons, mouseX, mouseY)) {
                        running = false;
                        break;
                    }
                }
            }
        }

        if (!running)
            break;

        fd_set readfds;
        FD_ZERO(&readfds);
        FD_SET(fd, &readfds);

        struct timeval timeout;
        timeout.tv_sec = 0;
        timeout.tv_usec = 100000;

        int result = select(fd + 1, &readfds, nullptr, nullptr, &timeout);

        if (result < 0) {
            if (errno == EINTR)
                continue;

            perror("select");
            break;
        }

        if (result == 0)
            continue;

        connected = processServerMessage(fd, framebuffer, window);
    }

    if (!connected)
        fprintf(stderr, "VNC connection lost or protocol error\n");

    SDL_FreeSurface(framebuffer);
    SDL_DestroyWindow(window);
    SDL_Quit();
    close(fd);

    return 0;
}
