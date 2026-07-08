/**
 * Frida hooks for NAC validation inside identityservicesd (macOS arm64e).
 *
 * Dumps validation blobs when NACSign succeeds — bypasses external dlopen/PAC limits.
 *
 * Usage:
 *   sudo frida -n identityservicesd -l nac_hooks.js
 *   # trigger validation: kappy-spike register, Messages iMessage toggle, or IDS login
 *
 * Offsets are RVAs from the identityservicesd Mach-O base (preferred 0x100000000).
 * Override at attach time:
 *   frida -n identityservicesd -l nac_hooks.js --parameters='{"profile":"26.5.1"}'
 */

'use strict';

const PROFILES = {
  '26.5.1': {
    module: 'identityservicesd',
    initWrapper: 0x8832cc,
    initBody: 0x2a7360,
    keyEst: 0x7e3a44,
    keyEstBody: 0x7e530c,
    sign: 0x7fd004,
    callSiteInit: [0x1da944, 0x1dbf90],
    callSiteKeyEst: 0x1dc754,
    callSiteSign: 0x1da914,
  },
  '15.0': {
    module: 'identityservicesd',
    initWrapper: 0x66b05c,
    initBody: 0x66b05c,
    keyEst: 0x64e200,
    keyEstBody: 0x64e200,
    sign: 0x67e4d8,
    callSiteInit: 0x257148,
    callSiteKeyEst: 0x257c28,
    callSiteSign: 0x255b30,
  },
};

function getProfile() {
  const wanted = (typeof profile !== 'undefined' && profile) ? profile : '26.5.1';
  const p = PROFILES[wanted];
  if (!p) {
    throw new Error('unknown profile: ' + wanted + ' (use 26.5.1 or 15.0)');
  }
  return p;
}

function modBase(name) {
  const m = Process.findModuleByName(name);
  if (!m) {
    throw new Error('module not loaded: ' + name + ' (is identityservicesd running?)');
  }
  return m.base;
}

function at(base, rva) {
  return base.add(rva);
}

function hex(ptr) {
  return ptr.toString();
}

function ts() {
  return new Date().toISOString();
}

function validUntilIso() {
  return new Date(Date.now() + 15 * 60 * 1000).toISOString().replace(/\.\d{3}Z$/, 'Z');
}

function bytesToBase64(byteArray) {
  const bytes = new Uint8Array(byteArray);
  if (ObjC.available) {
    const NSData = ObjC.classes.NSData;
    const ns = NSData.dataWithBytes_length_(bytes, bytes.length);
    return ns.base64EncodedStringWithOptions_(0).toString();
  }
  const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
  let out = '';
  for (let i = 0; i < bytes.length; i += 3) {
    const b0 = bytes[i];
    const b1 = i + 1 < bytes.length ? bytes[i + 1] : 0;
    const b2 = i + 2 < bytes.length ? bytes[i + 2] : 0;
    const n = (b0 << 16) | (b1 << 8) | b2;
    out += alphabet[(n >> 18) & 63];
    out += alphabet[(n >> 12) & 63];
    out += i + 1 < bytes.length ? alphabet[(n >> 6) & 63] : '=';
    out += i + 2 < bytes.length ? alphabet[n & 63] : '=';
  }
  return out;
}

function emitValidation(byteArray, source) {
  const b64 = bytesToBase64(byteArray);
  const payload = {
    type: 'validation',
    source: source,
    captured_at: ts(),
    len: byteArray.byteLength,
    validation_data: b64,
    valid_until: validUntilIso(),
    nacserv_commit: 'kappy-frida-nac-hook',
  };
  const json = JSON.stringify(payload);
  console.log('\n[kappy-nac] VALIDATION_JSON=' + json);
  send(payload);
}

function readOutBuffer(outDataPtr, outLenPtr) {
  if (outDataPtr.isNull() || outLenPtr.isNull()) {
    return null;
  }
  const dataPtr = outDataPtr.readPointer();
  const len = outLenPtr.readInt();
  if (dataPtr.isNull() || len <= 0 || len > 16 * 1024 * 1024) {
    return null;
  }
  return dataPtr.readByteArray(len);
}

function hookNacSign(base, cfg) {
  const addr = at(base, cfg.sign);
  console.log('[kappy-nac] hook NACSign @ ' + hex(addr) + ' (rva 0x' + cfg.sign.toString(16) + ')');
  Interceptor.attach(addr, {
    onEnter(args) {
      this.ctx = args[0];
      this.outDataPtr = args[3];
      this.outLenPtr = args[4];
      console.log('[kappy-nac] NACSign enter ctx=' + hex(this.ctx));
    },
    onLeave(retval) {
      const rc = retval.toInt32();
      console.log('[kappy-nac] NACSign leave rc=' + rc);
      if (rc !== 0) {
        return;
      }
      const buf = readOutBuffer(this.outDataPtr, this.outLenPtr);
      if (buf === null) {
        console.log('[kappy-nac] NACSign rc=0 but empty out buffer');
        return;
      }
      emitValidation(buf, 'NACSign@' + cfg.sign.toString(16));
    },
  });
}

function hookNacKeyEst(base, cfg) {
  const addr = at(base, cfg.keyEst);
  console.log('[kappy-nac] hook NACKeyEstablishment @ ' + hex(addr));
  Interceptor.attach(addr, {
    onEnter(args) {
      this.ctx = args[0];
      this.response = args[1];
      this.responseLen = args[2].toInt32();
      console.log('[kappy-nac] NACKeyEst enter ctx=' + hex(this.ctx) + ' responseLen=' + this.responseLen);
    },
    onLeave(retval) {
      console.log('[kappy-nac] NACKeyEst leave rc=' + retval.toInt32());
    },
  });
}

function hookNacInitWrapper(base, cfg) {
  if (!cfg.initWrapper) {
    return;
  }
  const addr = at(base, cfg.initWrapper);
  console.log('[kappy-nac] hook NACInit wrapper @ ' + hex(addr));
  Interceptor.attach(addr, {
    onEnter(args) {
      console.log('[kappy-nac] NACInit enter cert=' + hex(args[0]) + ' len=' + args[1].toInt32());
    },
    onLeave(retval) {
      console.log('[kappy-nac] NACInit leave rc=' + retval.toInt32());
    },
  });
}

function hookCallSites(base, cfg) {
  const sites = [];
  if (cfg.callSiteSign) {
    sites.push({ name: 'callSiteSign', rva: cfg.callSiteSign });
  }
  if (cfg.callSiteKeyEst) {
    sites.push({ name: 'callSiteKeyEst', rva: cfg.callSiteKeyEst });
  }
  const initSites = cfg.callSiteInit;
  if (initSites) {
    const list = Array.isArray(initSites) ? initSites : [initSites];
    list.forEach((rva, i) => sites.push({ name: 'callSiteInit' + i, rva: rva }));
  }
  sites.forEach((s) => {
    const addr = at(base, s.rva);
    console.log('[kappy-nac] hook ' + s.name + ' @ ' + hex(addr));
    Interceptor.attach(addr, {
      onEnter() {
        console.log('[kappy-nac] hit ' + s.name + ' @ ' + hex(addr));
      },
    });
  });
}

function main() {
  const cfg = getProfile();
  const base = modBase(cfg.module);
  console.log('[kappy-nac] profile=' + ((typeof profile !== 'undefined' && profile) ? profile : '26.5.1'));
  console.log('[kappy-nac] ' + cfg.module + ' base=' + hex(base));
  console.log('[kappy-nac] waiting for NAC activity — trigger register / iMessage / IDS login');

  hookNacInitWrapper(base, cfg);
  hookNacKeyEst(base, cfg);
  hookNacSign(base, cfg);
  hookCallSites(base, cfg);
}

rpc.exports = {
  ping() {
    return { ok: true, pid: Process.id, ts: ts() };
  },
};

main();
