variable "domains" {
  type = map(string)
  default = {
    "catfish-mountain-com" = "catfish-mountain.com"
    "yak-shave-com"        = "yak-shave.com"
    "benfulton-me"         = "benfulton.me"
    "fultonhuffman-com"    = "fultonhuffman.com"
  }
}
