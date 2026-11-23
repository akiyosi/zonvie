#include <stdio.h>

struct point {
    int x;
    int y;
};

static int clamp(int value, int low, int high)
{
    if (value < low) {
        return low;
    } else if (value > high) {
        return high;
    }
    return value;
}

int sum(const struct point *points, size_t count)
{
    int total = 0;
    for (size_t i = 0; i < count; i++) {
        switch (points[i].x) {
        case 0:
            continue;
        default:
            total += clamp(points[i].x, 0, count);
            break;
        }
    }
    while (total > 100) {
        total -= 1;
    }
    return total;
}
