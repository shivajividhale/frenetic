open ControllerInterface
open OpenFlow0x01Types
open Packet
open Platform
open Printf
open NetCoreSyntax

module CoqCtrl = FwOFSimpleExtractableController
module Atoms = FwOFNetworkAtoms.NetworkAtoms

module type POLICY = sig
  val policy : policy
  (* Necessary due to static compilation in FwOF. *)
  val switches : switchId list
end

(* Topology is not relevant for execution, only the proof. See the note below.
*)
module MakePolTopo (Policy : POLICY)  = struct

  (* Note: this is not relevant for execution. It is only needed for
     verification. The signatures in Coq (FwOFSignatures.v) should be better
     factored so that this cruft is not neeeded. *)
  let topo _ = None  

  let handlers = Hashtbl.create 0

  let pol = desugar_policy Policy.policy handlers

  let get_pkt out = 
    let open NetCoreEval in
    match out with
      | OutPkt (sw,PhysicalPort pt, pk, Datatypes.Coq_inl buf) ->
        Some (pt, (pk, buf))
      | OutPkt _ ->
        failwith "The verified controller requires policies that output to \
                  physical ports."
      | OutGetPkt _ -> 
        failwith "The verified controller cannot be run with a NetCore policy \
                  that queries the network."
      | OutNothing -> None
        

  let abst_func sw pt (pk,buf) = 
    let open NetCoreEval in
     
    let full = (classify pol (InPkt (sw,pt,pk, Some buf))) in
    let pks = Types.filter_map get_pkt full in
    pks
end


module Make (Platform : PLATFORM) (Policy : POLICY) = struct

  module PolTopo = MakePolTopo (Policy)
  module Controller = CoqCtrl.Make (PolTopo)

  type state = Controller.state

  let init_packet_out () = {
    Controller.pktsToSend = []; 
    Controller.switchStates = []
  }

  let compile_pol swId = 
    let f ((prio,pat),act) =  
      Controller.FlowMod (Atoms.AddFlow (prio, pat, act)) in
    let lst = Classifier.prioritize 65535
       (NetCoreCompiler.compile_opt PolTopo.pol swId) in
    { Controller.theSwId = swId;
      Controller.pendingCtrlMsgs = 
        Types.intersperse (Controller.BarrierRequest 0) (List.map f lst)
    }

  let init_flow_mod () = {
    Controller.pktsToSend = []; 
    Controller.switchStates = List.map compile_pol Policy.switches
  }

  let pending_switches : (switchId, bool) Hashtbl.t = Hashtbl.create 100

  let rec accept_switches () = 
    Lwt.bind (Platform.accept_switch ())
      (fun feats -> 
        (if Hashtbl.mem pending_switches feats.switch_id then
            begin
              eprintf "[VerifiedNetCore.ml] got switch %Ld.\n%!" 
                feats.switch_id;
              Hashtbl.remove pending_switches feats.switch_id
            end
        else
          eprintf "[VerifiedNetCore.ml]: unexpected connection from %Ld\n%!"
            feats.switch_id);
        if Hashtbl.length pending_switches > 0 then
          begin
            eprintf "[VerifiedNetCore.ml]: waiting for next switch.\n%!";
            accept_switches ()
          end
        else
          Lwt.return ())

  let create_recv_thread (send_msg_in: (switchId * Controller.fromSwitch) option -> unit) (swId : switchId) =
    Lwt.async
      (fun () ->
        let rec loop () = 
          Lwt.bind (Platform.recv_from_switch swId)
            (fun (xid,msg) ->
              match msg with
                | PacketInMsg { packetInBufferId = Some bufId;
                                packetInPort = pt; 
                                packetInPacket = pk } ->
                  send_msg_in
                    (Some (swId, Controller.PacketIn (pt, (pk, bufId))));
                  loop ()
                | _ -> loop ()) in
        loop ())

  let rec send_loop st = match Controller.send st with
    | None -> (st, [])
    | Some ((st, sw), msg) ->
      let (xid, ofMsg) = match msg with
        | Controller.FlowMod (Atoms.AddFlow (prio, pat, act)) ->
          (0l, FlowModMsg (NetCoreController.to_flow_mod prio pat act))
        | Controller.PacketOut (pt,(pk,bufId)) ->
          (0l, PacketOutMsg { 
            pktOutBufOrBytes = Datatypes.Coq_inl bufId;
            pktOutPortId = None;
            pktOutActions = [Output (PhysicalPort pt)] 
          })
        | Controller.BarrierRequest xid ->
          (Int32.of_int xid, BarrierRequest)
      in
      let (st, rest) = send_loop st in
      (st, (sw, xid, ofMsg) :: rest)

  let rec consolidate_pkt_out lst = match lst with
    | x :: y :: rest ->
      begin match (x,y) with
        | ((sw1, xid1, PacketOutMsg { pktOutBufOrBytes = bufId1;
                                 pktOutPortId = None;
                                 pktOutActions = pts1 }),
           (sw2, xid2, PacketOutMsg { pktOutBufOrBytes = bufId2;
                                 pktOutPortId = None;
                                 pktOutActions = pts2})) ->
          if sw1 = sw2 && bufId1 = bufId2 then
            consolidate_pkt_out 
              ((sw1, xid1, PacketOutMsg { pktOutBufOrBytes = bufId1;
                                          pktOutPortId = None;
                                          pktOutActions = pts1 @ pts2 })
               :: rest)
          else
            (x :: consolidate_pkt_out (y::rest))
        | _ -> x :: (consolidate_pkt_out (y::rest))
      end
    | x :: rest ->
      x :: (consolidate_pkt_out rest)
    | [] -> []
        

  let main_loop st msgs_in = 
    let rec loop st =
      Lwt.bind
        (Lwt_stream.next msgs_in)
        (fun (swId,msg) ->
          let st = Controller.recv st swId msg in
          let (st, to_send) = send_loop st in
          let to_send = consolidate_pkt_out to_send in
          Lwt_list.iter_s
            (fun (sw, xid,msg) -> Platform.send_to_switch sw xid msg)
            to_send >>
          loop st) in
    loop st

  let main_loop_thread init_state = 
    let (msgs_in, send_msg_in) = Lwt_stream.create () in
    List.iter (create_recv_thread send_msg_in) Policy.switches;
    Lwt.async (fun () -> main_loop init_state msgs_in)

  let start (init_state : state) = 
    List.iter (fun sw -> Hashtbl.add pending_switches sw true) Policy.switches;
    Lwt.bind (accept_switches ())
      (fun () -> 
        eprintf "[VerifiedNetCore.ml]: Got all switches, proceeding.\n%!";
        main_loop_thread init_state;
        Lwt.return ())        

end
