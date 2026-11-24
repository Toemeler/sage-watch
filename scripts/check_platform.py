import struct, sys
b = open(sys.argv[1], 'rb').read()
offs = [0]
if b[:4] == bytes.fromhex('cafebabe'):
    n = struct.unpack('>I', b[4:8])[0]
    offs = [struct.unpack('>IIIII', b[8 + 20 * i:28 + 20 * i])[2] for i in range(n)]
for off in offs:
    m = b[off:]; ncmds = struct.unpack('<I', m[16:20])[0]; p = 32
    for _ in range(ncmds):
        cmd, sz = struct.unpack('<II', m[p:p + 8])
        if cmd == 0x32:
            plat = struct.unpack('<I', m[p + 8:p + 12])[0]
            print('watch slice platform', plat)
            if plat != 4: sys.exit('watch app is not a watchOS binary')
        p += sz
