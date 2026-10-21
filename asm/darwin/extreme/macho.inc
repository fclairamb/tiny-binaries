// Mach-O header and load commands of a one-page arm64 executable, written by hand.
// Included first by hello.s and tcp.s, which define Lentry (the code). The whole
// file is one 16 KiB page mapped r-x at 0x100000000: header, commands, code, data,
// and the ad-hoc signature that sign.py writes at the end of the page.
// Every command here is required: see README.md for what fails without each one.

        .text
Lmh:    .long   0xfeedfacf              // MH_MAGIC_64
        .long   0x0100000c              // CPU_TYPE_ARM64
        .long   0                       // CPU_SUBTYPE_ARM64_ALL
        .long   2                       // MH_EXECUTE
        .long   5                       // ncmds
        .long   Lcmds_end - Lcmds       // sizeofcmds
        .long   0x00200004              // MH_DYLDLINK | MH_PIE: an arm64 executable must use dyld
        .long   0                       // reserved
Lcmds:
        // __PAGEZERO: 4 GiB with no access below the image, enforced by the kernel.
        .long   0x19, 72                // LC_SEGMENT_64
        .ascii  "__PAGEZERO\0\0\0\0\0\0"
        .quad   0, 0x100000000          // vmaddr, vmsize
        .quad   0, 0                    // fileoff, filesize
        .long   0, 0, 0, 0              // maxprot, initprot, nsects, flags

        // __TEXT: the whole file, r-x, no section headers. dyld finds it by name.
        .long   0x19, 72                // LC_SEGMENT_64
        .ascii  "__TEXT\0\0\0\0\0\0\0\0\0\0"
        .quad   0x100000000, 0x4000     // vmaddr, vmsize
        .quad   0, 0x4000               // fileoff, filesize
        .long   5, 5, 0, 0              // maxprot r-x, initprot r-x, nsects, flags

        .long   0xe, 32, 12             // LC_LOAD_DYLINKER, name at offset 12
        .ascii  "/usr/lib/dyld\0\0\0\0\0\0\0"

        .long   0x80000028, 24          // LC_MAIN: dyld calls Lentry(argc, argv, envp, apple)
        .quad   Lentry - Lmh, 0         // entryoff, stacksize

        .long   0x1d, 16, 0, 0          // LC_CODE_SIGNATURE: dataoff, datasize set by sign.py
Lcmds_end:
