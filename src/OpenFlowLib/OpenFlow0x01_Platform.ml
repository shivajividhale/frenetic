(** Low OpenFlow API.
    The Platform manages connections to switches for the
    controller. It provides functions to send and receive OpenFlow
    messages that do the necessary low-level serialization themselves.

    It is possible and instructive to build a controller directly atop
    [PLATFORM]. But, see [NetCore] for a higher-level abstraction.
*)
open Frenetic_Socket
open Frenetic_Log
open OpenFlow0x01
open OpenFlow0x01_Parser

exception SwitchDisconnected of switchId

let server_fd : Lwt_unix.file_descr option ref = 
  ref None

let max_pending : int = 
  64

let switch_fds : (switchId, Lwt_unix.file_descr) Hashtbl.t = 
  Hashtbl.create 101

let init_with_fd (fd : Lwt_unix.file_descr) : unit Lwt.t = 
  match !server_fd with
  | Some _ ->
    raise_lwt (Invalid_argument "Platform already initialized")
  | None ->
    server_fd := Some fd;
    Lwt.return ()
    
      
let init_with_port (port:int) : unit Lwt.t = 
  let open Lwt_unix in 
  let fd = socket PF_INET SOCK_STREAM 0 in
  setsockopt fd SO_REUSEADDR true;
  bind fd (ADDR_INET (Unix.inet_addr_any, port));
  listen fd max_pending;
  init_with_fd fd

let get_fd () : Lwt_unix.file_descr Lwt.t = 
  match !server_fd with 
    | Some fd -> 
      Lwt.return fd
    | None -> 
      raise_lwt (Invalid_argument "Platform not initialized")

let rec recv_from_switch_fd (sock : Lwt_unix.file_descr) : (xid * message) option Lwt.t =
  let ofhdr_str = String.create (2 * sizeof_ofp_header) in (* JNF: why 2x? *)
  lwt ok = SafeSocket.recv sock ofhdr_str 0 sizeof_ofp_header in
  if not ok then Lwt.return None
  else
    lwt hdr = Lwt.wrap (fun () -> Header.parse (Cstruct.of_string ofhdr_str)) in
    let body_len = hdr.Header.len - sizeof_ofp_header in
    let body_buf = String.create body_len in
    lwt ok = SafeSocket.recv sock body_buf 0 body_len in
    if not ok then Lwt.return None
    else 
      match Message.parse hdr (Cstruct.of_string body_buf) with
      | Some v -> 
        Lwt.return (Some v)
      | None ->
        Log.printf "platform" 
          "in recv_from_switch_fd, ignoring message with code %d\n%!"
          (msg_code_to_int hdr.Header.typ);
        recv_from_switch_fd sock

let send_to_switch_fd (sock : Lwt_unix.file_descr) (xid : xid) (msg : message) : unit option Lwt.t =
  try_lwt
    lwt msg_buf = Lwt.wrap2 Message.marshal xid msg in
    let msg_len = String.length msg_buf in
    lwt sent = Lwt_unix.write sock msg_buf 0 msg_len in
    if sent <> msg_len then
      Lwt.return None
    else
      Lwt.return (Some ())
  with Unix.Unix_error (err, fn, arg) ->
    Log.printf "platform"
      "in send_to_switch_fd, %s\n%!"
      (Unix.error_message err);
    Lwt.return None

let fd_of_switch_id (sw:switchId) : Lwt_unix.file_descr option =  
  try
    Some (Hashtbl.find switch_fds sw)
  with Not_found -> 
    None

let disconnect_switch (sw:switchId) : unit Lwt.t = match fd_of_switch_id sw with 
  | Some fd -> 
    lwt _ = Lwt_unix.close fd in
    Hashtbl.remove switch_fds sw;
    Lwt.return ()
  | None -> 
    Lwt.return ()
      
let shutdown () : unit = 
  Lwt.ignore_result 
    (lwt fd = get_fd () in 
     lwt _ = Lwt_unix.close fd in 
     Lwt_list.iter_p
       Lwt_unix.close
       (Hashtbl.fold (fun _ fd l -> fd::l) switch_fds []))

let send_to_switch (sw : switchId) (xid : xid) (msg : message) : unit Lwt.t =
  match fd_of_switch_id sw with 
  | Some fd -> 
    lwt ok = send_to_switch_fd fd xid msg in 
    begin match ok with 
      | Some () -> 
        Lwt.return ()
      | None -> 
        lwt _ = disconnect_switch sw in 
        raise_lwt (SwitchDisconnected sw)
    end
  | None -> 
    raise_lwt (SwitchDisconnected sw)

let rec recv_from_switch (sw : switchId) : (xid * message) Lwt.t = 
  match fd_of_switch_id sw with
    | Some fd -> 
      begin 
        lwt resp = recv_from_switch_fd fd in 
        match resp with
          | Some (xid, EchoRequest bytes) ->
            begin 
              send_to_switch sw xid (EchoReply bytes) >>
              recv_from_switch sw
            end
          | Some (xid, msg) -> 
            Lwt.return (xid, msg)
          | None -> 
            raise_lwt (SwitchDisconnected sw)
      end
    | None -> 
      raise_lwt (SwitchDisconnected sw)
        
let switch_handshake (fd : Lwt_unix.file_descr) : features option Lwt.t =
  lwt ok = send_to_switch_fd fd 0l (Hello (Cstruct.of_string "")) in
  match ok with 
    | Some () -> 
      lwt resp = recv_from_switch_fd fd in 
      begin match resp with 
        | Some (_, Hello _) ->
          begin 
            lwt ok = send_to_switch_fd fd 0l FeaturesRequest in
            match ok with 
              | Some () -> 
                begin 
                  lwt resp = recv_from_switch_fd fd in 
                  match resp with 
                    | Some (_,FeaturesReply feats) ->
                      Hashtbl.add switch_fds feats.switch_id fd;
                      Log.printf "platform" 
                        "switch %Ld connected\n%!"
                        feats.switch_id;
                      Lwt.return (Some feats)
                    | _ -> 
                      Lwt.return None
                end
              | None -> 
                Lwt.return None
          end
        | Some _ -> 
          Lwt.return None
        | None -> 
          Lwt.return None
      end 
    | None -> 
      Lwt.return None

(* TODO(arjun): a switch can stall during a handshake, while another
   switch is ready to connect. To be fully robust, this module should
   have a dedicated thread to accept TCP connections, a thread per new
   connection to handle handshakes, and a queue of accepted switches.
   Then, accept_switch will simply dequeue (or block if the queue is
   empty). *)
let rec accept_switch () =
  lwt server_fd = get_fd () in 
  lwt (fd, sa) = Lwt_unix.accept server_fd in
  let _ = Log.printf "platform" "%s connected, handshaking...\n%!" (string_of_sockaddr sa) in 
  lwt ok = switch_handshake fd in 
  match ok with 
    | Some feats -> 
      Lwt.return feats
    | None -> 
      lwt _ = Lwt_unix.close fd in
      Log.printf "platform" "%s disconnected, trying again...\n%!"
        (string_of_sockaddr sa);
      accept_switch ()
        
        