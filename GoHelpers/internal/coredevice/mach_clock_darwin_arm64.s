#include "textflag.h"

TEXT ·machContinuousTime(SB),NOSPLIT,$0-8
	BL	libc_mach_continuous_time(SB)
	MOVD	R0, ret+0(FP)
	RET

TEXT ·getMachTimebaseInfo(SB),NOSPLIT,$0-12
	MOVD	info+0(FP), R0
	BL	libc_mach_timebase_info(SB)
	MOVW	R0, ret+8(FP)
	RET
