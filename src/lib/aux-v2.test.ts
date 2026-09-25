import { afterEach, describe, expect, test } from "bun:test";
import { auxCanListen, auxCanRemove, auxInvitation, auxMediaURL, auxPosition, auxRequest, clearAuxConnection, restoreAuxConnection, saveAuxConnection, type AuxConnection, type AuxState } from "./aux-v2";

const guest: AuxConnection = {server:"https://aux.example",session_id:"aux_test",participant_id:"guest-one",token:"participant-secret",role:"guest",expires_at:Date.now()/1000+3600};
const track = {fingerprint:"song",title:"Song",artist:"Artist",album:"Album",duration_seconds:240,media_url:"/api/v2/aux/sessions/aux_test/tracks/song/audio",artwork_url:""};
const state: AuxState = {schema:"codec.aux.v2",session_id:"aux_test",mode:"listen_together",host_name:"Host",role:"guest",participant_id:"guest-one",expires_at:guest.expires_at,revision:1,server_time_ms:1000,anchor_time_ms:1000,position_seconds:20,status:"playing",current:{entry_id:"now",participant_id:"host",track},queue:[],allow_saves:false,allow_contributions:true};
const realFetch = globalThis.fetch;
const realStorage = globalThis.localStorage;
afterEach(() => { globalThis.fetch = realFetch; Object.defineProperty(globalThis,"localStorage",{value:realStorage,configurable:true}); });

describe("Aux credential boundary", () => {
  test("joining and restoring a guest cannot replace the owner's saved login", () => {
    const values = new Map([["codec.syncToken","private-owner"],["codec.syncServer","https://personal.example"]]);
    Object.defineProperty(globalThis,"localStorage",{value:{getItem:(key:string)=>values.get(key)??null,setItem:(key:string,value:string)=>values.set(key,value),removeItem:(key:string)=>values.delete(key)},configurable:true});
    saveAuxConnection(guest);
    expect(restoreAuxConnection("https://personal.example","private-owner")).toEqual(guest);
    clearAuxConnection();
    expect([...values]).toEqual([["codec.syncToken","private-owner"],["codec.syncServer","https://personal.example"]]);
    saveAuxConnection({...guest,role:"host",token:"private-owner"});
    expect(values.get("codec.aux.v2.connection")).not.toContain("private-owner");
    expect(restoreAuxConnection("https://different.example","wrong-owner")).toBeNull();
  });
  test("media credentials never escape the current session or disclose owner tokens", () => {
    expect(new URL(auxMediaURL(guest,state,track.media_url)).searchParams.get("access_token")).toBe(guest.token);
    for (const url of ["https://other.example"+track.media_url,"/api/v1/library","/api/v2/aux/sessions/other/tracks/song/audio","/api/v2/aux/sessions/aux_test/tracks/../state"]) {
      expect(auxMediaURL(guest,state,url)).toBe("");
    }
    const host = {...guest,role:"host" as const,token:"owner-secret"};
    expect(auxMediaURL(host,state,track.media_url)).toBe("");
    const media=auxMediaURL(host,{...state,media_token:"scoped-media"},track.media_url+"?access_token=old");
    expect(media).not.toContain("owner-secret");
    expect(new URL(media).searchParams.get("access_token")).toBe("scoped-media");
  });
  test("guest requests omit cookies, reject redirects, and use only their explicit token", async () => {
    let sent:RequestInit|undefined;
    globalThis.fetch=(async (_url:unknown,init?:RequestInit)=>{sent=init;return new Response(JSON.stringify(state));}) as typeof fetch;
    await auxRequest(guest.server,"/api/v2/aux/sessions/aux_test/state",guest.token);
    expect(sent?.credentials).toBe("omit");expect(sent?.redirect).toBe("error");expect(sent?.cache).toBe("no-store");
    expect(new Headers(sent?.headers).get("Authorization")).toBe("Bearer participant-secret");
  });
  test("legacy invitations cannot silently join through broad-access credentials", () => {
    expect(()=>auxInvitation("ABCD",guest.server)).toThrow("Old four-character codes");
    const secret="auxi_"+"f".repeat(64);
    expect(auxInvitation(`${guest.server}/#aux=${secret}`)).toEqual({server:guest.server,secret});
    expect(()=>auxInvitation(`${guest.server}/?aux=ABCD`)).toThrow();
  });
});

test("separate listeners never compete for the owner's selected speaker", () => {
  expect(auxCanListen(state,"guest-device")).toBe(true);
  expect(auxCanListen({...state,mode:"shared_speaker"},"guest-device")).toBe(false);
  const host={...state,role:"host" as const,mode:"shared_speaker" as const,host_device_id:"speaker"};
  expect(auxCanListen(host,"speaker")).toBe(true);expect(auxCanListen(host,"other-device")).toBe(false);
});
test("guest removal and timeline calculation honor session ownership", () => {
  expect(auxCanRemove(state,{entry_id:"own",participant_id:guest.participant_id,track})).toBe(true);
  expect(auxCanRemove(state,{entry_id:"other",participant_id:"another-guest",track})).toBe(false);
  expect(auxPosition(state,1000,3000)).toBe(22);
  expect(auxPosition({...state,status:"paused"},1000,3000)).toBe(20);
  expect(auxPosition(state,1000,500000)).toBe(240);
});
