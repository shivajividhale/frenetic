open Printf
open Packet
open NetCore_Types.External
open NetCore_Action.Output

(** Table relating private locations to public locations. *)
module type TABLE = sig
  type t

  (** [create min_port max_port] bounds the range of ports*)
  val create : tpPort -> tpPort -> t

   (** [fresh_public_port private_ip private_port = private_port] where
       [private_port is unused] *)
  val fresh_public_port : t -> nwAddr -> tpPort -> tpPort

  val get_public_port : t -> nwAddr -> tpPort -> tpPort option

  (** [get_private_address public_port = (private_ip, private_port)] *)
  val get_private_addr : t -> tpPort -> (nwAddr * tpPort) option

end


module Table : TABLE = struct

  type t = {
    min_port : tpPort;
    max_port : tpPort;
    map : (tpPort, nwAddr * tpPort) Hashtbl.t;
    map_rev : (nwAddr * tpPort, tpPort) Hashtbl.t;
  }

  let create min max =
    assert (min < max);
    {
      min_port = min;
      max_port = max;
      map = Hashtbl.create 100;
      map_rev = Hashtbl.create 100
    }

  let fresh_public_port tbl private_ip private_port = 
    let rec loop public_port = 
      if public_port < tbl.min_port then 
        failwith "NAT is out of ports"
      else if Hashtbl.mem tbl.map public_port then
        (* Assumes max_port <= 65535 and 65535 + 1 fits in tpPort (int) *)
        loop ((public_port + 1) mod (tbl.max_port + 1))
      else
        begin
          Hashtbl.add tbl.map public_port (private_ip, private_port);
          Hashtbl.add tbl.map_rev (private_ip, private_port) public_port;
          public_port
        end in
    loop tbl.min_port

  let get_public_port tbl private_ip private_port = 
    try
      Some (Hashtbl.find tbl.map_rev (private_ip, private_port))
    with Not_found -> None 

  let get_private_addr tbl public_port = 
    try Some (Hashtbl.find tbl.map public_port)
    with Not_found -> None

end

let make (public_ip : nwAddr) =
  let (stream, push) = Lwt_stream.create () in
  let tbl = Table.create 2000 65535 in
  let rec init_public_pol sw pt pk =
    match pk with
      | { pktDlTyp = 0x800;
          pktNwHeader = NwIP {
            pktIPSrc = src_ip;
            pktIPDst = dst_ip;
            pktIPProto = 6;
            pktTpHeader = TpTCP { tcpSrc = src_pt; tcpDst = dst_pt }
          }
        } -> 
        eprintf "[NAT] firewall dropping IP packet from %s:%d to %s:%d\n%!"
          (string_of_ip src_ip) src_pt (string_of_ip dst_ip) dst_pt;
        drop 
      | _ -> eprintf "[NAT] firewalling non IP packet.\n%!"; drop in
                      
  let rec callback sw pt pk =
    match pk with
      | { pktDlTyp = 0x800;
          pktNwHeader = NwIP {
            pktIPSrc = private_ip;
            pktIPProto = 6;
            pktTpHeader = TpTCP { tcpSrc = private_port }
          }
        } ->
        begin match Table.get_public_port tbl private_ip private_port with
          | Some public_port ->
            seq_action
              (updateSrcIP private_ip public_ip)
              (updateSrcPort private_port public_port)
          | None ->
            let public_port =
              Table.fresh_public_port tbl private_ip private_port in
            Printf.eprintf "[NAT] translating %s:%d to %s:%d\n%!"
              (string_of_ip private_ip) private_port
              (string_of_ip public_ip) public_port;
            private_pol :=
              ITE (And (SrcIP private_ip, TcpSrcPort private_port),
                   Seq (Act (UpdateSrcIP (private_ip, public_ip)),
                        Act (UpdateSrcPort (private_port, public_port))),
                   !private_pol);
            public_pol :=
              ITE (And (DstIP public_ip, TcpDstPort public_port),
                   Seq (Act (UpdateDstIP (public_ip, private_ip)),
                        Act (UpdateDstPort (public_port, private_port))),
                   !public_pol);
            push (Some (!private_pol, !public_pol));
            seq_action
              (updateSrcIP private_ip public_ip)
              (updateSrcPort private_port public_port)
        end
      | _ -> NetCore_Action.Output.drop
  and private_pol = ref (Act (GetPacket callback))
  and public_pol = ref (Act (GetPacket init_public_pol)) in
  let pair_stream =
    NetCore_Stream.from_stream (!private_pol, !public_pol) stream in
  (NetCore_Stream.map (fun (priv, _) -> priv) pair_stream,
   NetCore_Stream.map (fun (_, pub) -> pub) pair_stream)