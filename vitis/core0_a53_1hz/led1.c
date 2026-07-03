#include "xparameters.h"
#include "xgpiops.h"
#include "sleep.h"
#include "xil_cache.h"

#define LED_PIN     78
#define MY_SLOT     0
#define SYNC_ADDR   0x10000000U

int main(void)
{
    XGpioPs_Config *cfg;
    XGpioPs gpio;
    volatile u32 *sync = (volatile u32 *)SYNC_ADDR;

    cfg = XGpioPs_LookupConfig(XPAR_XGPIOPS_0_BASEADDR);
    if (cfg == NULL) return 1;
    if (XGpioPs_CfgInitialize(&gpio, cfg, cfg->BaseAddr) != XST_SUCCESS) return 1;

    XGpioPs_SetDirectionPin(&gpio, LED_PIN, 1);
    XGpioPs_SetOutputEnablePin(&gpio, LED_PIN, 1);

    Xil_DCacheInvalidateRange((UINTPTR)sync, 5U * sizeof(u32));
    u32 gen = sync[4] + 1U;

    sync[MY_SLOT] = gen;
    Xil_DCacheFlushRange((UINTPTR)&sync[MY_SLOT], sizeof(u32));

    do {
        Xil_DCacheInvalidateRange((UINTPTR)sync, 4U * sizeof(u32));
    } while (sync[0] != gen || sync[1] != gen || sync[2] != gen || sync[3] != gen);

    sync[4] = gen;
    Xil_DCacheFlushRange((UINTPTR)&sync[4], sizeof(u32));

    while (1) {
        XGpioPs_WritePin(&gpio, LED_PIN, 1);
        usleep(500000);
        XGpioPs_WritePin(&gpio, LED_PIN, 0);
        usleep(500000);
    }
    return 0;
}
