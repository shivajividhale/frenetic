type 'a t

val map : ('a -> 'b) -> 'a t -> 'b t
val map2 : ('a -> 'b -> 'c) -> 'a t -> 'b t -> 'c t
val now : 'a t -> 'a
val constant : 'a -> 'a t
val from_stream : 'a -> 'a Lwt_stream.t -> 'a t
val to_stream : 'a t -> 'a Lwt_stream.t