-module(bitplus).

%%-export([compress/1, decompress/1, empty/0, size_compressed/1, size_uncompressed/1]).
-compile(export_all).

-record(bitplus, {data}).

compress(Bin1) when is_bitstring(Bin1) ->
    #bitplus{data=compress_(Bin1)}.

decompress(#bitplus{data=B}) ->
    decompress_(B).

empty() -> compress(<<>>).

size_compressed(#bitplus{data=B}) -> bit_size(B).
%% FIXME: the implementation for size_uncompressed is naive. Must be possible to do this without decompression.
size_uncompressed(B) when is_record(B, bitplus) -> bit_size(decompress(B)).

%% get nth bit from bitmap
get(#bitplus{data=B}, N) ->
    void.

%% Internal functions

%%
%% Decompression
%%

decompress_(B) ->
    Words = decompose(B),
    Bins = lists:reverse(decompress_(Words, [])),
    list_to_bitstring(Bins). % join the list of 31-bit bitstrings into 1 long bitstring. 

decompress_([{fill, 0, N}|Rest], Acc) -> decompress_(Rest, replicate(all_zeros31(), N) ++ Acc);
decompress_([{fill, 1, N}|Rest], Acc) -> decompress_(Rest, replicate(all_ones31(), N) ++ Acc);
decompress_([{literal, _Length, Literal}|Rest], Acc) -> decompress_(Rest, [Literal|Acc]);
decompress_([], Acc) -> Acc.

%% split a compressed bitstring (bitplus) into words.
decompose(B) ->
    lists:reverse(decompose(B, [])).
decompose(B, Acc) when bit_size(B) > 64 -> % not the last 2 words - (fill words + literal words)
    RestSize = bit_size(B) - 32,
    <<G:32, Rest:RestSize>> = B,
    G1 = case <<G:32>> of
            <<2#10:2, N:30>> -> {fill, 0, N};
            <<2#11:2, N:30>> -> {fill, 1, N};
            <<2#0:1, Literal:31>> -> {literal, 31, <<Literal:31>>}
    end,
    decompose(<<Rest:RestSize>>, [G1|Acc]);
decompose(B, Acc) when bit_size(B) == 64 -> % last 2 words - (active word + mask word)
    <<A:32, M:32>> = B,
    G1 = case <<M:32>> of
        <<32:32>> -> % all 32 bits of active word are meaningful
            case <<A:32>> of
                <<2#10:2, N:30>> -> {fill, 0, N};
                <<2#11:2, N:30>> -> {fill, 1, N};
                <<2#0:1, Literal:31>> -> {literal, 31, <<Literal:31>>}
            end;
        <<N:32>> -> % only N bits of active word are meaningful
            {literal, N, <<A:N>>}
    end,
    [G1|Acc].

%% replicate supplied W n times in a list & return the list.
replicate(W, N) -> replicate(W, N, []).
replicate(W, N, Acc) when N > 0 -> replicate(W, N-1, [W|Acc]);
replicate(_W, N, Acc) when N == 0 -> Acc.

%%
%% Compression
%% 

compress_(Bin) ->
    L = split31(Bin),
    Words = lists:reverse(compress_(L, [])),
    list_to_bitstring(Words). %  join list of words into 1 long bitstring
    
compress_([H|Rest], Acc) when bit_size(H) == 31 ->
    Pat1 = all_ones31(),
    Pat0 = all_zeros31(),
    case H of
        Pat1 -> % 1-fill word
            {Remaining, Count} = check_consecutive(Pat1, Rest, 0),
            compress_(Remaining, [fill_word_1(1+Count)|Acc]);
        Pat0 -> % 0-fill word
            {Remaining, Count} = check_consecutive(Pat0, Rest, 0),
            compress_(Remaining, [fill_word_0(1+Count)|Acc]);
        _ -> % literal word
            compress_(Rest, [literal_word(H)|Acc])
    end;
compress_([H|_Rest], Acc) when bit_size(H) < 31 ->
    %% "active word" (last word) is just a word which has <31 useful bits.
    %% active word is followed by another word (lets call it "mask word") which stores
    %% an integer representing the no. of useful bits in the active word.
    [mask_word(bit_size(H))|[active_word(H)|Acc]];
compress_([], Acc) ->
    [mask_word(32)|Acc].

active_word(H) ->
    HSize = bit_size(H),
    <<H1:HSize>> = H,
    <<H1:32>>.

mask_word(HSize) -> <<HSize:32>>.

%% literal words always begin with 0 followed by the 31-bits provided as-is (hence the name literal).
literal_word(<<H:31>>) -> <<2#0:1, H:31>>.

%% fill words always begin with 1 followed by the fill-bit (1 or 0)
fill_word_0(N) -> <<2#10:2, N:30>>. % generate a 0-fill word representing N 31-bit 0 bitstrings
fill_word_1(N) -> <<2#11:2, N:30>>.

%% split given bitstring into 31-bit bitstrings.
split31(Bin) ->
    lists:reverse(split31(Bin, [])).
split31(Bin, Acc) when bit_size(Bin) > 31 ->
    RestSize = bit_size(Bin) - 31,
    <<G:31,Rest:RestSize>> = Bin,
    split31(<<Rest:RestSize>>, [<<G:31>>|Acc]);
split31(Bin, Acc) when bit_size(Bin) =< 31 ->
    [Bin|Acc].

check_consecutive(Pattern, [H|Rest], Count) ->
    case H of
        Pattern ->
            check_consecutive(Pattern, Rest, Count+1);
        _ ->
            {[H|Rest], Count}
    end.

all_ones31() -> <<2#1111111111111111111111111111111:31>>.
all_zeros31() -> <<2#0000000000000000000000000000000:31>>.
is_all_ones31(<<2#1111111111111111111111111111111:31>>) -> true;
is_all_ones31(_) -> false.
is_all_zeros31(<<2#0000000000000000000000000000000:31>>) -> true;
is_all_zeros31(_) -> false.